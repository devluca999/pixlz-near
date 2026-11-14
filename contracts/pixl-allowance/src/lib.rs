//! A Pixl's allowance, enforced on chain.
//!
//! The contract account holds the Pixl's funds. The only key the Mac holds for it is a
//! function-call key limited to `pay`; the account has no full-access key. So whatever runs on
//! the Mac, the most it can do is ask this contract to pay, and the contract decides:
//!   - only to the one payee the owner set,
//!   - at most `max_per_call` per payment and `max_per_day` per UTC day,
//!   - never while paused, never below the storage reserve.
//! The owner (a separate account, signing in their own wallet) changes limits, pauses, or
//! withdraws everything back to themselves.

use near_sdk::json_types::U128;
use near_sdk::{env, log, near, require, AccountId, NearToken, PanicOnDefault, Promise};

const DAY_NS: u64 = 86_400 * 1_000_000_000;

#[near(contract_state)]
#[derive(PanicOnDefault)]
pub struct Allowance {
    owner: AccountId,
    payee: AccountId,
    max_per_call: u128,
    max_per_day: u128,
    paused: bool,
    day: u64,
    spent_today: u128,
    paid_total: u128,
    payments: u64,
}

#[near(serializers = [json])]
pub struct Config {
    pub owner: AccountId,
    pub payee: AccountId,
    pub max_per_call: U128,
    pub max_per_day: U128,
    pub paused: bool,
    pub spent_today: U128,
    pub paid_total: U128,
    pub payments: u64,
    pub balance: U128,
}

#[near]
impl Allowance {
    #[init]
    pub fn new(owner: AccountId, payee: AccountId, max_per_call: U128, max_per_day: U128) -> Self {
        require!(max_per_call.0 <= max_per_day.0, "max_per_call can't exceed max_per_day");
        require!(payee != env::current_account_id(), "the payee can't be the allowance itself");
        Self { owner, payee, max_per_call: max_per_call.0, max_per_day: max_per_day.0, paused: false,
               day: env::block_timestamp() / DAY_NS, spent_today: 0, paid_total: 0, payments: 0 }
    }

    /// Pay the payee `amount` yoctoNEAR. Only the account itself (its function-call key) may call it.
    pub fn pay(&mut self, amount: U128, memo: Option<String>) -> Promise {
        require!(env::predecessor_account_id() == env::current_account_id(), "only the Pixl's own key can pay");
        require!(!self.paused, "paused by the owner");
        require!(amount.0 > 0, "amount must be more than 0");
        require!(amount.0 <= self.max_per_call, "over the per-payment cap");
        let today = env::block_timestamp() / DAY_NS;
        if today != self.day {
            self.day = today;
            self.spent_today = 0;
        }
        require!(self.spent_today + amount.0 <= self.max_per_day, "over today's cap");
        let reserve = env::storage_byte_cost().as_yoctonear() * u128::from(env::storage_usage());
        require!(env::account_balance().as_yoctonear() >= reserve + amount.0, "not enough above the storage reserve");
        self.spent_today += amount.0;
        self.paid_total += amount.0;
        self.payments += 1;
        log!("pixl-allowance pay {} to {} memo {}", amount.0, self.payee, memo.unwrap_or_default().chars().take(64).collect::<String>());
        Promise::new(self.payee.clone()).transfer(NearToken::from_yoctonear(amount.0))
    }

    // -- owner only --

    pub fn set_limits(&mut self, max_per_call: U128, max_per_day: U128) {
        self.only_owner();
        require!(max_per_call.0 <= max_per_day.0, "max_per_call can't exceed max_per_day");
        self.max_per_call = max_per_call.0;
        self.max_per_day = max_per_day.0;
    }

    pub fn set_payee(&mut self, payee: AccountId) {
        self.only_owner();
        require!(payee != env::current_account_id(), "the payee can't be the allowance itself");
        self.payee = payee;
    }

    pub fn set_paused(&mut self, paused: bool) {
        self.only_owner();
        self.paused = paused;
    }

    /// Everything above the storage reserve goes back to the owner.
    pub fn withdraw(&mut self) -> Promise {
        self.only_owner();
        let reserve = env::storage_byte_cost().as_yoctonear() * u128::from(env::storage_usage());
        let free = env::account_balance().as_yoctonear().saturating_sub(reserve);
        require!(free > 0, "nothing to withdraw");
        Promise::new(self.owner.clone()).transfer(NearToken::from_yoctonear(free))
    }

    // -- views --

    pub fn get_config(&self) -> Config {
        let today = env::block_timestamp() / DAY_NS;
        Config { owner: self.owner.clone(), payee: self.payee.clone(), max_per_call: U128(self.max_per_call),
                 max_per_day: U128(self.max_per_day), paused: self.paused,
                 spent_today: U128(if today == self.day { self.spent_today } else { 0 }),
                 paid_total: U128(self.paid_total), payments: self.payments,
                 balance: U128(env::account_balance().as_yoctonear()) }
    }

    fn only_owner(&self) {
        require!(env::predecessor_account_id() == self.owner, "only the owner");
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use near_sdk::test_utils::VMContextBuilder;
    use near_sdk::testing_env;

    const N: u128 = 1_000_000_000_000_000_000_000_000;

    fn ctx(predecessor: &str, day: u64) {
        testing_env!(VMContextBuilder::new()
            .current_account_id("allowance.testnet".parse().unwrap())
            .predecessor_account_id(predecessor.parse().unwrap())
            .account_balance(NearToken::from_yoctonear(5 * N))
            .block_timestamp(day * DAY_NS + 1)
            .build());
    }

    fn fresh() -> Allowance {
        ctx("allowance.testnet", 100);
        Allowance::new("owner.testnet".parse().unwrap(), "payee.testnet".parse().unwrap(), U128(N / 100), U128(N / 10))
    }

    #[test]
    fn its_own_key_pays_within_caps() {
        let mut a = fresh();
        a.pay(U128(N / 200), None);
        assert_eq!(a.get_config().spent_today.0, N / 200);
        assert_eq!(a.get_config().payments, 1);
    }

    #[test]
    #[should_panic(expected = "only the Pixl's own key can pay")]
    fn nobody_else_can_pay() {
        let mut a = fresh();
        ctx("attacker.testnet", 100);
        a.pay(U128(1), None);
    }

    #[test]
    #[should_panic(expected = "over the per-payment cap")]
    fn per_payment_cap() {
        let mut a = fresh();
        a.pay(U128(N), None);
    }

    #[test]
    fn daily_cap_holds_then_resets_the_next_day() {
        let mut a = fresh();
        for _ in 0..10 { a.pay(U128(N / 100), None); }
        let over = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| { let mut b = Allowance { ..clone(&a) }; b.pay(U128(1), None); }));
        assert!(over.is_err(), "the 11th payment must be refused");
        ctx("allowance.testnet", 101);
        a.pay(U128(N / 100), None);
        assert_eq!(a.get_config().spent_today.0, N / 100);
    }

    #[test]
    #[should_panic(expected = "paused by the owner")]
    fn owner_can_pause() {
        let mut a = fresh();
        ctx("owner.testnet", 100);
        a.set_paused(true);
        ctx("allowance.testnet", 100);
        a.pay(U128(1), None);
    }

    #[test]
    #[should_panic(expected = "only the owner")]
    fn the_pixl_cannot_raise_its_own_limits() {
        let mut a = fresh();
        a.set_limits(U128(N), U128(N));
    }

    #[test]
    #[should_panic(expected = "only the owner")]
    fn the_pixl_cannot_change_the_payee() {
        let mut a = fresh();
        a.set_payee("attacker.testnet".parse().unwrap());
    }

    fn clone(a: &Allowance) -> Allowance {
        Allowance { owner: a.owner.clone(), payee: a.payee.clone(), max_per_call: a.max_per_call, max_per_day: a.max_per_day,
                    paused: a.paused, day: a.day, spent_today: a.spent_today, paid_total: a.paid_total, payments: a.payments }
    }
}

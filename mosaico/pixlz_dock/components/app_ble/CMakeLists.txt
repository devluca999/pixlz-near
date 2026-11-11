# Device only: the simulator has no Bluetooth (game.sim.json doesn't list it).
idf_component_register(
    SRCS "app_ble.c"
    INCLUDE_DIRS "include"
    PRIV_REQUIRES bt lwip freertos esp_common log
)

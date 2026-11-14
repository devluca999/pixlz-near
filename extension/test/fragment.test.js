import { test } from "node:test";
import assert from "node:assert/strict";
import {
  buildDirective, buildFragmentUrl, countOccurrences, encodeTerm, splitSelection, startTerm, stripDirective, trimPartialWords,
} from "../fragment.js";
import { FROGG, PALETTE, froggPixels } from "../icon.js";

const URL_ = "https://example.com/article";

test("delimiters are escaped inside terms", () => {
  assert.equal(encodeTerm("a-b, c&d"), "a%2Db%2C%20c%26d");
});

test("a short, unique selection links to itself", () => {
  assert.equal(buildFragmentUrl(URL_, { text: "the quick  brown\nfox" }), `${URL_}#:~:text=the%20quick%20brown%20fox`);
});

test("partial words at the edges are dropped", () => {
  assert.equal(trimPartialWords("ick brown fo", "the qu", "x jumps"), "brown");
  assert.equal(trimPartialWords("quick brown fox", "the ", " jumps"), "quick brown fox");
  assert.equal(trimPartialWords("brown", "quick ", ", fox"), "brown");
  assert.equal(buildDirective({ text: "ick", before: "qu", after: "ly" }), null);
  // from a live test on en.wikipedia.org/wiki/Frog: "…ward off predators (aposemat" + "ism)"
  assert.equal(trimPartialWords("ward off predators (aposemat", "and ", "ism)"), "ward off predators");
  assert.equal(trimPartialWords("“Frogs are", "", ""), "Frogs are");
});

test("long selections use start and end terms", () => {
  const text = "Frogs absorb water and oxygen through their thin skin, which is why they are sensitive to pollution in ponds";
  assert.equal(buildDirective({ text }), "text=Frogs%20absorb%20water%20and,to%20pollution%20in%20ponds");
});

test("ambiguous selections get a prefix and suffix", () => {
  const d = buildDirective({ text: "the frog", before: "On Monday we saw ", after: " on a lily pad.", occurrences: 3 });
  assert.equal(d, "text=Monday%20we%20saw-,the%20frog,-on%20a%20lily");
});

test("existing #hash is kept and an old directive replaced", () => {
  assert.equal(buildFragmentUrl(`${URL_}#section-2`, { text: "frog" }), `${URL_}#section-2:~:text=frog`);
  assert.equal(stripDirective(`${URL_}#:~:text=old`), URL_);
  assert.equal(buildFragmentUrl(`${URL_}#:~:text=old`, { text: "new" }), `${URL_}#:~:text=new`);
  assert.equal(buildFragmentUrl(`${URL_}#top:~:text=old`, { text: "new" }), `${URL_}#top:~:text=new`);
});

test("nothing linkable returns the plain URL", () => {
  assert.equal(buildFragmentUrl(URL_, { text: "   " }), URL_);
});

test("non-Latin text and punctuation", () => {
  assert.equal(buildDirective({ text: "Grüße – よろしく。" }), "text=" + encodeURIComponent("Grüße – よろしく"));
  assert.equal(trimPartialWords("üße aus", "Gr", " Berlin"), "aus");
});

test("occurrence counting ignores case and whitespace", () => {
  assert.equal(countOccurrences("The frog.\nthe   FROG sat. the frog", "the frog"), 3);
  assert.equal(countOccurrences("abc", ""), 0);
});

test("icon is 16×16 and every pixel has a color", () => {
  assert.equal(FROGG.length, 16);
  for (const row of FROGG) {
    assert.equal(row.length, 16);
    for (const ch of row) assert.ok(ch === "." || PALETTE[ch], `unknown pixel ${ch}`);
  }
  const { width, data } = froggPixels(2);
  assert.equal(width, 32);
  assert.equal(data.length, 32 * 32 * 4);
});

test("prefix and suffix sit right next to the trimmed term, not the raw selection", () => {
  // "ick brown fo" in "the quick brown fox jumps": term "brown", so prefix ends "quick", suffix starts "fox".
  assert.deepEqual(splitSelection("ick brown fo", "see the qu", "x jumps over"),
    { text: "brown", before: "see the quick ", after: " fox jumps over" });
  assert.equal(buildDirective({ text: "ick brown fo", before: "see the qu", after: "x jumps over", occurrences: 2 }),
    "text=see%20the%20quick-,brown,-fox%20jumps%20over");
  // edge punctuation trimmed off goes to the context too
  assert.equal(buildDirective({ text: "“Frogs are”", before: "he said ", after: " loudly", occurrences: 2 }),
    "text=he%20said%20%E2%80%9C-,Frogs%20are,-%E2%80%9D%20loudly");
});

test("startTerm is the start term the link carries", () => {
  assert.equal(startTerm({ text: "ick brown fo", before: "qu", after: "x" }), "brown");
  const long = "Frogs absorb water and oxygen through their thin skin, which is why they are sensitive to pollution in ponds";
  assert.equal(startTerm({ text: long }), "Frogs absorb water and");
  assert.equal(startTerm({ text: "ick", before: "qu", after: "ly" }), null);
});

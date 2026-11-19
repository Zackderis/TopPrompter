// Offline test of the speech-following logic: swiftc ../Follower.swift FollowerTests.swift
import Foundation

var failures = 0
func check(_ cond: Bool, _ msg: String) { if !cond { failures += 1; print("FAIL:", msg) } else { print("ok:  ", msg) } }

let script = """
Most founders think outbound is dead. It's not. The problem is the list.
Here's how I build a list of leads in Apollo that actually replies.
Step one: open Apollo and filter by the companies that are hiring.
The the the. Step two: export the leads and write one line per person.
"""

// Simulate how partial results grow word by word.
func speak(_ f: Follower, _ text: String, base: String = "") {
    var t = base
    for w in text.split(separator: " ") { t += (t.isEmpty ? "" : " ") + w; f.feed(t) }
}

do { // reads straight through
    let f = Follower(); f.load(script)
    speak(f, "most founders think outbound is dead it's not the problem is the list")
    check(f.cursor == 13, "straight read lands after 'list' (cursor \(f.cursor))")
}
do { // repeated partials don't run ahead on common words
    let f = Follower(); f.load(script)
    for _ in 0..<10 { f.feed("most founders think outbound is dead it's not the") }
    check(f.cursor == 9, "repeated identical partial stays put (cursor \(f.cursor))")
}
do { // silence/unrelated chatter doesn't move it
    let f = Follower(); f.load(script)
    speak(f, "okay hang on let me get some water")
    check(f.cursor == 0, "unrelated chatter doesn't move (cursor \(f.cursor))")
}
do { // skipping a sentence is picked up after 3 words
    let f = Follower(); f.load(script)
    speak(f, "most founders think outbound is dead")
    speak(f, "here's how i build a list", base: "most founders think outbound is dead")
    let idx = f.words.firstIndex { $0.norm == "build" }!
    check(f.cursor >= idx + 1, "skip ahead to 'here's how I build' (cursor \(f.cursor), build at \(idx))")
}
do { // misrecognised word (plural / small typo) still tracks
    let f = Follower(); f.load(script)
    f.cursor = f.words.firstIndex { $0.norm == "step" }!
    speak(f, "step one open apollo and filter by the company that are hiring")
    let idx = f.words.firstIndex { $0.norm == "hiring" }!
    check(f.cursor == idx + 1, "fuzzy match 'company'→'companies' (cursor \(f.cursor), want \(idx + 1))")
}
do { // "the the the" doesn't skip ahead
    let f = Follower(); f.load(script)
    let start = f.words.firstIndex { $0.norm == "hiring" }! + 1
    f.cursor = start
    speak(f, "the")
    check(f.cursor == start + 1, "single 'the' advances exactly one (cursor \(f.cursor), want \(start + 1))")
}
do { // recognizer restart (fresh transcript) continues from cursor
    let f = Follower(); f.load(script)
    speak(f, "most founders think outbound is dead")
    speak(f, "it's not the problem")
    check(f.cursor == 10, "continues after recognizer restart (cursor \(f.cursor))")
}

do { // a stray short word that appears a few words ahead doesn't jump there
    let f = Follower(); f.load("we want to grow the pipeline and the team")
    speak(f, "we want")
    speak(f, "the", base: "we want")   // misheard / filler 'the' 2 words ahead
    check(f.cursor == 2, "stray 'the' doesn't jump ahead (cursor \(f.cursor))")
    speak(f, "to grow the", base: "we want the")
    check(f.cursor == 5, "then tracks normally (cursor \(f.cursor))")
}

print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)

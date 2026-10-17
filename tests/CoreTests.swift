import Foundation
import ApplicationServices

@main
struct CoreTests {
    static func main() throws {
        let fn: CGEventFlags = .maskSecondaryFn
        let leftShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x2)
        let rightShift = CGEventFlags(rawValue: CGEventFlags.maskShift.rawValue | 0x4)
        var gesture = FnGesture()
        check(gesture.consume(type: .flagsChanged, key: 63, flags: fn).trigger == false, "Fn press waits for release")
        check(gesture.consume(type: .flagsChanged, key: 63, flags: fn).trigger == false, "Fn repeat ignored")
        check(gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger && gesture.triggeredMode == .dictate, "Fn release starts dictate")
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger, "duplicate release ignored")

        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 10)
        check(gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 10.59).trigger, "short Fn press triggers")
        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 20)
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 20.61).trigger && gesture.ignoredLongPress, "long Fn press produces hint without recording")
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 21)
        check(gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 21.1).trigger && !gesture.ignoredLongPress, "short press works after ignored long press")

        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 30)
        check(!gesture.consumeLongPress(now: 30.59), "hold hint waits for the threshold")
        check(gesture.consumeLongPress(now: 30.6) && gesture.down, "hold hint fires while Fn is still down")
        check(!gesture.consumeLongPress(now: 31), "held key produces only one hint")
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 32).trigger && !gesture.ignoredLongPress, "release after timed hint neither records nor repeats the hint")

        gesture = FnGesture()
        check(gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 40, isRecording: true).trigger, "second Fn press stops a recording immediately")
        check(gesture.longPressDeadline == nil && !gesture.consumeLongPress(now: 41), "stopping gesture cannot turn into a long-hold warning")
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 41).trigger, "duplicate Fn down after stopping cannot start again")
        check(!gesture.consume(type: .flagsChanged, key: 56, flags: fn.union(leftShift), now: 41.1).trigger, "Shift added after stopping cannot start translation")
        _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn, now: 41.2)
        let stoppedAsk = gesture.consume(type: .keyDown, key: 49, flags: fn, now: 41.3)
        check(!stoppedAsk.trigger && stoppedAsk.suppress, "Space added after stopping neither starts Ask nor inserts a space")
        check(gesture.consume(type: .keyUp, key: 49, flags: fn, now: 41.4).suppress, "stop chord consumes matching Space release")
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 42).trigger, "release after stopping cannot start a new recording")
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 43)
        check(gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 43.1).trigger, "next independent short press starts normally")

        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 50)
        _ = gesture.consume(type: .keyDown, key: 123, flags: fn, now: 50.1)
        check(gesture.longPressDeadline == nil && !gesture.consumeLongPress(now: 51), "Fn arrow chord cancels hold timer")
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate] {
            gesture = FnGesture()
            check(!gesture.consume(type: .flagsChanged, key: 63, flags: fn.union(modifier), isRecording: true).trigger, "pre-existing unrelated modifier does not stop recording")
        }

        for order in [true, false] {
            gesture = FnGesture()
            if order {
                _ = gesture.consume(type: .flagsChanged, key: 56, flags: leftShift)
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn.union(leftShift))
            } else {
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn)
                _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn.union(leftShift))
            }
            check(!gesture.consume(type: .flagsChanged, key: 63, flags: leftShift).trigger, "translation waits for held Shift after Fn release")
            check(gesture.consume(type: .flagsChanged, key: 56, flags: []).trigger && gesture.triggeredMode == .translate, "left Shift translation starts on full release in either press order")
        }
        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn)
        _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn.union(leftShift))
        _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn)
        check(gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger && gesture.triggeredMode == .translate, "translation survives Shift-first release")

        for order in [true, false] {
            gesture = FnGesture()
            if order {
                _ = gesture.consume(type: .flagsChanged, key: 60, flags: rightShift)
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn.union(rightShift))
            } else {
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn)
                _ = gesture.consume(type: .flagsChanged, key: 60, flags: fn.union(rightShift))
            }
            check(!gesture.consume(type: .flagsChanged, key: 63, flags: rightShift).trigger, "translation waits for right Shift release")
            check(gesture.consume(type: .flagsChanged, key: 60, flags: []).trigger && gesture.triggeredMode == .translate, "right Shift translation works in either order")
        }
        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 56, flags: leftShift)
        _ = gesture.consume(type: .flagsChanged, key: 60, flags: leftShift.union(rightShift))
        _ = gesture.consume(type: .flagsChanged, key: 56, flags: rightShift)
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn.union(rightShift))
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: rightShift).trigger, "released left Shift does not remain down while right Shift held")

        for shiftKey: Int64 in [56, 60] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 80)
            check(gesture.consumeLongPress(now: 81), "lone Fn expires before translation chord")
            _ = gesture.consume(type: .flagsChanged, key: shiftKey, flags: fn.union(.maskShift), now: 82)
            check(gesture.longPressDeadline == nil, "explicit translation chord has no short-press deadline")
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: .maskShift, now: 84)
            check(gesture.consume(type: .flagsChanged, key: shiftKey, flags: [], now: 85).trigger && gesture.triggeredMode == .translate,
                  "slow Fn Shift chord starts translation exactly on full release")
            check(!gesture.consume(type: .flagsChanged, key: shiftKey, flags: [], now: 86).trigger, "translation release never repeats")
        }

        for fnReleasedFirst in [false, true] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 100)
            let ask = gesture.consume(type: .keyDown, key: 49, flags: fn, now: 100.1)
            check(ask.trigger && ask.suppress && gesture.triggeredMode == .ask && gesture.longPressDeadline == nil, "Fn Space starts Ask on Space-down and cancels the hold deadline")
            let repeated = gesture.consume(type: .keyDown, key: 49, flags: fn, now: 100.2)
            check(!repeated.trigger && repeated.suppress, "held Space does not repeat ask or type spaces")
            if fnReleasedFirst {
                check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 100.3).trigger, "Fn release waits for held Space")
            }
            let up = gesture.consume(type: .keyUp, key: 49, flags: fnReleasedFirst ? [] : fn, now: 100.4)
            check(!up.trigger && up.suppress, "Space release cannot toggle Ask again")
            if !fnReleasedFirst {
                check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 100.5).trigger, "Fn release cannot toggle Ask again")
            }
            check(!gesture.consume(type: .keyDown, key: 49, flags: [], now: 100.55).suppress, "next ordinary Space passes through")
        }
        for fnReleasedFirst in [false, true] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 110)
            _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn.union(leftShift), now: 110.2)
            if fnReleasedFirst {
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: leftShift, now: 110.3)
            } else {
                _ = gesture.consume(type: .flagsChanged, key: 56, flags: fn, now: 110.3)
            }
            check(!gesture.consumeLongPress(now: 110.59) && !gesture.consumeLongPress(now: 110.6),
                  "explicit translation chord is not expired by the lone Fn hold deadline")
            check(!gesture.consumeLongPress(now: 111), "long chord emits one warning")
            let finalRelease = gesture.consume(type: .flagsChanged, key: fnReleasedFirst ? 56 : 63, flags: [], now: 111.1)
            check(finalRelease.trigger && gesture.triggeredMode == .translate && !gesture.ignoredLongPress,
                  "releasing held translation starts once without a long-press warning")
        }
        for timerFired in [false, true] {
            for fnReleasedFirst in [false, true] {
                gesture = FnGesture()
                _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 120)
                if timerFired { check(gesture.consumeLongPress(now: 120.6), "lone Fn hold expires before Space") }
                let ask = gesture.consume(type: .keyDown, key: 49, flags: fn, now: 121.2)
                check(ask.trigger && ask.suppress && gesture.triggeredMode == .ask,
                      "Space starts Ask even after a slow Fn hold, with or without timer delivery")
                check(!gesture.consumeLongPress(now: 123), "held Ask has no long-press warning")
                check(!gesture.consume(type: .keyDown, key: 49, flags: fn, now: 124, isRecording: true).trigger,
                      "Space autorepeat cannot stop the recording")
                if fnReleasedFirst {
                    check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 125, isRecording: true).trigger,
                          "late Fn-first release does not stop Ask")
                }
                let spaceUp = gesture.consume(type: .keyUp, key: 49, flags: fnReleasedFirst ? [] : fn, now: 126, isRecording: true)
                check(!spaceUp.trigger && spaceUp.suppress, "late Space release stays consumed")
                if !fnReleasedFirst {
                    check(!gesture.consume(type: .flagsChanged, key: 63, flags: [], now: 127, isRecording: true).trigger,
                          "late Fn-last release does not stop Ask")
                }
                check(gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 128, isRecording: true).trigger,
                      "next independent Fn press stops Ask immediately")
                check(!gesture.consume(type: .keyDown, key: 49, flags: fn, now: 128.1).trigger,
                      "adding Space to a stop gesture cannot restart Ask")
            }
        }
        for invalidKey: Int64 in [0, 123] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 130)
            _ = gesture.consumeLongPress(now: 131)
            _ = gesture.consume(type: .keyDown, key: invalidKey, flags: fn, now: 131.1)
            let space = gesture.consume(type: .keyDown, key: 49, flags: fn, now: 131.2)
            check(!space.trigger && !space.suppress, "unrelated key prevents a timed-out Fn from rearming Ask")
        }
        gesture = FnGesture()
        _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 140)
        _ = gesture.consumeLongPress(now: 141)
        _ = gesture.consume(type: .flagsChanged, key: 55, flags: fn.union(.maskCommand), now: 141.1)
        _ = gesture.consume(type: .flagsChanged, key: 55, flags: fn, now: 141.2)
        check(!gesture.consume(type: .keyDown, key: 49, flags: fn, now: 141.3).trigger,
              "releasing an unrelated modifier cannot rearm Ask after a Fn hold")

        for key: Int64 in [0, 53, 123, 124, 125, 126] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn)
            _ = gesture.consume(type: .keyDown, key: key, flags: fn)
            _ = gesture.consume(type: .keyUp, key: key, flags: fn)
            check(!gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger, "Fn combination cancels isolated-Fn trigger")
        }
        for modifier: CGEventFlags in [.maskCommand, .maskControl, .maskAlternate] {
            gesture = FnGesture()
            _ = gesture.consume(type: .flagsChanged, key: 63, flags: fn)
            _ = gesture.consume(type: .flagsChanged, key: 55, flags: fn.union(modifier))
            _ = gesture.consume(type: .flagsChanged, key: 55, flags: fn)
            check(!gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger, "released modifier does not re-arm Fn")
        }
        gesture = FnGesture()
        _ = gesture.consume(type: .keyDown, key: 123, flags: fn)
        _ = gesture.consume(type: .keyUp, key: 123, flags: fn)
        check(!gesture.consume(type: .flagsChanged, key: 63, flags: []).trigger, "arrow-provided function flag never arms Fn")

        for controlKey: Int64 in [59, 62] {
            for controlFirst in [false, true] {
                for fnReleasedFirst in [false, true] {
                    gesture = FnGesture()
                    if controlFirst { _ = gesture.consume(type: .flagsChanged, key: controlKey, flags: .maskControl, now: 200) }
                    _ = gesture.consume(type: .flagsChanged, key: 63, flags: controlFirst ? fn.union(.maskControl) : fn, now: 201)
                    if !controlFirst {
                        _ = gesture.consumeLongPress(now: 202)
                        _ = gesture.consume(type: .flagsChanged, key: controlKey, flags: fn.union(.maskControl), now: 203)
                    }
                    check(gesture.longPressDeadline == nil, "Fn Control has no hold timeout")
                    let first = gesture.consume(type: .flagsChanged, key: fnReleasedFirst ? 63 : controlKey,
                                                flags: fnReleasedFirst ? .maskControl : fn, now: 204)
                    check(!first.trigger, "context waits for both keys to release")
                    check(gesture.consume(type: .flagsChanged, key: fnReleasedFirst ? controlKey : 63, flags: [], now: 205).trigger && gesture.triggeredMode == .context,
                          "both Controls and both press/release orders start context, not translation")
                    check(!gesture.consume(type: .flagsChanged, key: controlKey, flags: [], now: 206).trigger, "context release cannot repeat")
                    check(gesture.consume(type: .flagsChanged, key: 63, flags: fn, now: 207, isRecording: true).trigger, "Fn stops context immediately")
                    _ = gesture.consume(type: .flagsChanged, key: controlKey, flags: fn.union(.maskControl), now: 208)
                    _ = gesture.consume(type: .flagsChanged, key: 63, flags: .maskControl, now: 209)
                    check(!gesture.consume(type: .flagsChanged, key: controlKey, flags: [], now: 210).trigger, "Control added to stop cannot restart context")
                }
            }
        }
        check(InputMode.translate.shortcut == "Fn ⇧" && InputMode.context.shortcut == "Fn ⌃", "shortcut labels match routing")
        let pasteModifiers: CGEventFlags = [.maskCommand, .maskControl]
        var paste = PasteLastGesture()
        var pasteCount = 0
        let performPaste = { pasteCount += 1; return true }
        check(paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: false, perform: performPaste), "paste shortcut consumes the first key down")
        check(paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: false, perform: performPaste), "duplicate key down stays suppressed")
        check(paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: true, perform: performPaste), "autorepeat stays suppressed")
        check(pasteCount == 1, "one physical paste chord inserts exactly once")
        check(!paste.consume(type: .keyDown, key: 9, flags: .maskCommand, isRepeat: false, isOwnEvent: true, perform: performPaste), "generated Cmd V down reaches the destination")
        check(!paste.consume(type: .keyUp, key: 9, flags: .maskCommand, isRepeat: false, isOwnEvent: true, perform: performPaste), "generated Cmd V up reaches the destination")
        _ = paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: true, perform: performPaste)
        check(pasteCount == 1, "generated paste events cannot rearm the physical chord")
        check(paste.consume(type: .keyUp, key: 9, flags: [], isRepeat: false, perform: performPaste), "physical release resets chord even when modifiers released first")
        _ = paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: false, perform: performPaste)
        check(pasteCount == 2, "a second physical press pastes once more")
        _ = paste.consume(type: .keyUp, key: 9, flags: [], isRepeat: false, perform: performPaste)
        _ = paste.consume(type: .keyDown, key: 9, flags: pasteModifiers, isRepeat: true, perform: performPaste)
        check(pasteCount == 2, "orphan autorepeat never pastes")
        _ = paste.consume(type: .keyUp, key: 9, flags: [], isRepeat: false, perform: performPaste)
        check(!paste.consume(type: .keyDown, key: 9, flags: [], isRepeat: false, perform: performPaste), "ordinary V passes through")
        check(!paste.consume(type: .keyUp, key: 9, flags: [], isRepeat: false, perform: performPaste), "ordinary V release passes through")
        let generatedPasteEvent = CGEvent(keyboardEventSource: nil, virtualKey: 9, keyDown: true)!
        check(generatedPasteEvent.getIntegerValueField(.eventSourceUnixProcessID) == Int64(ProcessInfo.processInfo.processIdentifier), "synthetic paste event identifies this process without posting it")

        let answer = try Gateway.parseAnswer("{\"action\":\"answer\",\"text\":\"  answer\\n\"}", hasSelection: true)
        check(answer == Gateway.Answer(text: "answer", replacesSelection: false), "ordinary answer never overwrites selection")
        let edit = "{\"action\":\"replace\",\"text\":\"第一行\\n第二行\"}"
        check(tryResult(edit, selection: true) == Gateway.Answer(text: "第一行\n第二行", replacesSelection: true), "explicit edit can replace selection")
        check(tryResult(edit, selection: false) == Gateway.Answer(text: "第一行\n第二行", replacesSelection: false), "replace without selection becomes an answer")
        for malformed in ["[]", "{}", "null", "not json", "{\"action\":\"delete\",\"text\":\"x\"}",
                          "{\"action\":\"answer\",\"text\":\" \\n\"}", "{\"action\":\"answer\",\"text\":1}",
                          "```json\n{\"action\":\"answer\",\"text\":\"x\"}\n```"] {
            do { _ = try Gateway.parseAnswer(malformed, hasSelection: true); fatalError("Expected invalid assistant response") }
            catch { }
        }
        print("PASS: Fn sequences, hold timer, immediate stop, chord suppression, paste-repeat suppression, synthetic-event passthrough and safe assistant-response parsing")
    }

    static func tryResult(_ input: String, selection: Bool) -> Gateway.Answer? {
        try? Gateway.parseAnswer(input, hasSelection: selection)
    }

    static func check(_ condition: @autoclosure () -> Bool, _ label: String) {
        precondition(condition(), "FAIL: \(label)")
    }
}

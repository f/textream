import Foundation

// A new recognizer has never installed an input tap. Stopping it must not
// initialize the microphone or block Classic-mode startup on an audio device.
let recognizer = SpeechRecognizer()
recognizer.forceStop()
recognizer.forceStop()
precondition(!recognizer.isListening && !recognizer.isStarting)
print("Audio cleanup without recording passed")

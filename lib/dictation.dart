import 'package:speech_to_text/speech_to_text.dart';

Future<bool> prepareDictation(
  SpeechToText speech, {
  required SpeechStatusListener onStatus,
  required SpeechErrorListener onError,
}) async {
  if (!await speech.initialize()) return false;
  // The plugin shares one instance across screens and initializes it only once.
  speech.statusListener = onStatus;
  speech.errorListener = onError;
  return true;
}

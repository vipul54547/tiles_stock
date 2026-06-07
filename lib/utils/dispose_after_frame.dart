import 'package:flutter/widgets.dart';

/// Disposes a [ChangeNotifier] (e.g. a [TextEditingController] or [FocusNode])
/// after the current frame, rather than immediately.
///
/// Controllers used inside a dialog/bottom-sheet are typically disposed as soon
/// as `showDialog`/`showModalBottomSheet`'s future resolves. But at that moment
/// the dialog's widget tree (and the [TextField] that depends on the controller)
/// has not finished unmounting yet. Disposing synchronously then trips the
/// framework's `'_dependents.isEmpty': is not true` assertion and shows a red
/// error screen.
///
/// Deferring to a post-frame callback lets those elements unmount first, so the
/// controller has no remaining dependents and disposes safely.
///
/// Pass one or more notifiers; they are all disposed in the same callback.
void disposeAfterFrame(List<ChangeNotifier> notifiers) {
  WidgetsBinding.instance.addPostFrameCallback((_) {
    for (final n in notifiers) {
      n.dispose();
    }
  });
}

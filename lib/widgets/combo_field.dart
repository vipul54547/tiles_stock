import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A field you can TYPE into, ARROW through, or TAP — a text box that filters a
/// list of options shown right underneath it.
///
/// Built for the stock / order / dispatch entry bars, where the stockist works
/// at a keyboard and must never have to reach for the mouse. Before this, Brand
/// and Design opened a tap-only sheet and Surface/Quality were tap-only
/// dropdowns, so a whole line could not be entered from the keyboard at all.
///
/// One line of entry is now:
///
///   f ↓ Tab   delt ↓ Tab   m ↓ Tab   p ↓ Tab   40 Enter
///
/// Keys:
///  • any text — filters the options as you type
///  • ↓ / ↑    — move through the matches, and the one you land on is SELECTED
///               as you go (a real dropdown selects while you arrow — this does
///               the same, so ↓ alone is enough to choose)
///  • Enter    — take the highlighted match and close (with nothing to take,
///               fires [onSubmitted] — that is how Enter on a last field can Add)
///  • Tab      — take the highlighted match AND move to the next field
///  • Esc      — close the list, leaving the value alone
///  • tap      — opens the full list; tapping a row selects it
///
/// Works the same on Windows, web and Android: the list is an overlay pinned to
/// the field, flipped above it when there is no room below (a field near the
/// bottom of a phone screen).
class ComboField<T> extends StatefulWidget {
  final T? value;
  final List<T> options;

  /// The text shown for an option — and what typing is matched against.
  final String Function(T) labelOf;

  /// Optional grey detail on the right of a row (size, box count…). Also
  /// searchable, so typing "600" finds a design by its size.
  final String Function(T)? detailOf;

  final ValueChanged<T> onSelected;
  final String hint;
  final bool enabled;

  /// Draw the border red — the field is required and still empty.
  final bool hasError;

  /// Fired on Enter when there is no match to take. The entry bar uses it on the
  /// quantity field to Add the line.
  final VoidCallback? onSubmitted;

  final FocusNode? focusNode;

  const ComboField({
    super.key,
    required this.value,
    required this.options,
    required this.labelOf,
    required this.onSelected,
    this.detailOf,
    this.hint = 'Select',
    this.enabled = true,
    this.hasError = false,
    this.onSubmitted,
    this.focusNode,
  });

  @override
  State<ComboField<T>> createState() => _ComboFieldState<T>();
}

const _navy = Color(0xFF1B4F72);
const _rowH = 42.0;
const _maxMenuH = 260.0;

class _ComboFieldState<T> extends State<ComboField<T>> {
  final _link = LayerLink();
  final _menu = OverlayPortalController();
  final _ctrl = TextEditingController();
  final _scroll = ScrollController();
  late FocusNode _focus;
  bool _ownsFocus = false;

  /// True once the stockist has typed since focusing. Until then the list shows
  /// EVERY option — clicking in should show what is on offer, not just the one
  /// thing already selected.
  bool _typed = false;
  int _hi = 0;

  /// Menu sits above the field instead of below (no room below — a field near
  /// the bottom of a phone screen).
  bool _above = false;

  @override
  void initState() {
    super.initState();
    _focus = widget.focusNode ?? FocusNode();
    _ownsFocus = widget.focusNode == null;
    _focus.addListener(_onFocusChange);
    _ctrl.text = _labelOfValue;
  }

  @override
  void didUpdateWidget(covariant ComboField<T> old) {
    super.didUpdateWidget(old);
    // The parent changed the value under us — a design pick prefilling the
    // surface, or a reset after Add. Only overwrite what is on screen when the
    // stockist is not mid-type, or we would eat their keystrokes.
    if (old.value != widget.value && !_typed) {
      _ctrl.text = _labelOfValue;
    }
  }

  @override
  void dispose() {
    _focus.removeListener(_onFocusChange);
    if (_ownsFocus) _focus.dispose();
    _ctrl.dispose();
    _scroll.dispose();
    super.dispose();
  }

  String get _labelOfValue =>
      widget.value == null ? '' : widget.labelOf(widget.value as T);

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _open();
    } else {
      _close(restore: true);
    }
  }

  void _open() {
    if (!widget.enabled) return;
    _typed = false;
    _hi = _indexOfValue();
    _above = _noRoomBelow();
    _ctrl.selection =
        TextSelection(baseOffset: 0, extentOffset: _ctrl.text.length);
    if (!_menu.isShowing) _menu.show();
    if (mounted) setState(() {});
  }

  void _close({bool restore = false}) {
    if (restore) {
      // Whatever half-typed text is sitting there is not a value. Put the real
      // one back, so the box never shows something that was not chosen.
      _ctrl.text = _labelOfValue;
      _typed = false;
    }
    if (_menu.isShowing) _menu.hide();
    if (mounted) setState(() {});
  }

  /// Not enough space under the field for the menu → show it above.
  bool _noRoomBelow() {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return false;
    final top = box.localToGlobal(Offset.zero).dy;
    final below = MediaQuery.sizeOf(context).height - (top + box.size.height);
    return below < 160 && top > below;
  }

  int _indexOfValue() {
    if (widget.value == null) return 0;
    final i = _matches.indexOf(widget.value as T);
    return i < 0 ? 0 : i;
  }

  /// Options matching what has been typed. Prefix matches come first — typing
  /// "p" should land on Premium, not on something that merely contains a "p".
  ///
  /// Read from the controller only while [_typed]: arrowing SELECTS as it goes,
  /// and if selecting rewrote the box the match list would collapse under the
  /// stockist mid-arrow. The box keeps the query; the value moves.
  List<T> get _matches {
    final q = _ctrl.text.trim().toLowerCase();
    if (!_typed || q.isEmpty) return widget.options;
    final starts = <T>[];
    final contains = <T>[];
    for (final o in widget.options) {
      final label = widget.labelOf(o).toLowerCase();
      final detail = widget.detailOf?.call(o).toLowerCase() ?? '';
      if (label.startsWith(q)) {
        starts.add(o);
      } else if (label.contains(q) || detail.contains(q)) {
        contains.add(o);
      }
    }
    return [...starts, ...contains];
  }

  /// Selected while arrowing: the value changes, the typed query stays put and
  /// the list stays open so ↑/↓ can keep moving.
  void _selectLive(T o) {
    widget.onSelected(o);
    setState(() {});
  }

  /// Taken for good — Enter, Tab, or a tap on the row.
  void _commit(T o) {
    _typed = false;
    _ctrl.text = widget.labelOf(o);
    _ctrl.selection = TextSelection.collapsed(offset: _ctrl.text.length);
    if (_menu.isShowing) _menu.hide();
    widget.onSelected(o);
    setState(() {});
  }

  void _move(int delta) {
    final m = _matches;
    if (m.isEmpty) return;
    if (!_menu.isShowing) {
      _above = _noRoomBelow();
      _menu.show();
    }
    _hi = (_hi + delta).clamp(0, m.length - 1);
    _selectLive(m[_hi]); // arrowing IS selecting
    _scrollToHighlight(m.length);
  }

  void _scrollToHighlight(int count) {
    if (!_scroll.hasClients) return;
    final view = _scroll.position.viewportDimension;
    final target = _hi * _rowH;
    if (target < _scroll.offset) {
      _scroll.jumpTo(target);
    } else if (target + _rowH > _scroll.offset + view) {
      _scroll.jumpTo(
          (target + _rowH - view).clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final m = _matches;
    // Only take a match on Enter/Tab if the stockist actually engaged with the
    // list. Otherwise a plain Tab THROUGH an untouched field would silently pick
    // whatever happened to be first.
    final engaged = _typed && m.isNotEmpty && _hi < m.length;

    switch (e.logicalKey) {
      case LogicalKeyboardKey.arrowDown:
        _move(1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.arrowUp:
        _move(-1);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.escape:
        _close(restore: true);
        return KeyEventResult.handled;
      case LogicalKeyboardKey.enter:
      case LogicalKeyboardKey.numpadEnter:
        if (engaged) {
          _commit(m[_hi]);
        } else {
          _close(restore: true);
          widget.onSubmitted?.call();
        }
        return KeyEventResult.handled;
      case LogicalKeyboardKey.tab:
        // Take what is highlighted, then let focus travel on as normal. This is
        // what makes `m` Tab mean "MATT, next field".
        if (engaged) _commit(m[_hi]);
        return KeyEventResult.ignored;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final border = widget.hasError
        ? Colors.red.shade300
        : (_focus.hasFocus ? _navy : Colors.grey.shade400);

    return OverlayPortal(
      controller: _menu,
      overlayChildBuilder: (_) => _menuOverlay(),
      child: CompositedTransformTarget(
        link: _link,
        child: Focus(
          // Not a tab stop of its own and never focused — it sits between the
          // text field and the app's text-editing shortcuts purely to see the
          // keys first, so ↑/↓ move the list instead of the caret.
          canRequestFocus: false,
          skipTraversal: true,
          onKeyEvent: _onKey,
          child: Container(
            height: 44,
            decoration: BoxDecoration(
              color: widget.enabled ? null : Colors.grey.shade100,
              border:
                  Border.all(color: border, width: _focus.hasFocus ? 1.6 : 1.0),
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.only(left: 10),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _ctrl,
                    focusNode: _focus,
                    enabled: widget.enabled,
                    style: const TextStyle(fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: widget.hint,
                      hintStyle:
                          TextStyle(fontSize: 13, color: Colors.grey.shade500),
                    ),
                    onTap: _open,
                    onChanged: (_) {
                      _typed = true;
                      _hi = 0;
                      if (!_menu.isShowing) {
                        _above = _noRoomBelow();
                        _menu.show();
                      }
                      setState(() {});
                    },
                  ),
                ),
                // The arrow is the affordance: this is a dropdown, click it.
                InkWell(
                  onTap: widget.enabled
                      ? () {
                          if (_menu.isShowing) {
                            _close(restore: true);
                          } else {
                            _focus.requestFocus();
                            _open();
                          }
                        }
                      : null,
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(
                        _menu.isShowing
                            ? Icons.arrow_drop_up
                            : Icons.arrow_drop_down,
                        size: 22,
                        color: Colors.grey.shade600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _menuOverlay() {
    final m = _matches;
    final box = context.findRenderObject() as RenderBox?;
    final w = box?.size.width ?? 220;

    // Positioned MUST be the outermost widget here — the overlay's Stack is its
    // parent, and anything wrapped around it (a TapRegion, say) leaves it with
    // no Stack to attach its parent data to. That throws, and a release build
    // paints the exception as a grey box over the whole screen.
    // Order matters, and getting it wrong breaks the menu in two different ways:
    //
    //  • Positioned must be OUTERMOST — the overlay's Stack is its parent, and
    //    anything wrapped around it leaves it no Stack to attach parent data to.
    //    That throws, and a release build paints the exception as a grey box over
    //    the whole screen.
    //  • The follower must sit ABOVE TextFieldTapRegion. TapRegion is a proxy box
    //    that bounds-checks `size.contains(position)` BEFORE passing the hit down;
    //    put it outside the follower and that check runs in the untransformed
    //    space, rejects every point, and no row is ever clickable.
    //
    // TextFieldTapRegion itself is what lets a row be tapped at all: without it
    // the tap counts as "outside the text field", TextField.onTapOutside
    // unfocuses, and the menu closes before the press lands.
    return Positioned(
      width: w < 220 ? 220 : w,
      child: CompositedTransformFollower(
        link: _link,
        showWhenUnlinked: false,
        targetAnchor: _above ? Alignment.topLeft : Alignment.bottomLeft,
        followerAnchor: _above ? Alignment.bottomLeft : Alignment.topLeft,
        offset: Offset(0, _above ? -4 : 4),
        child: TextFieldTapRegion(
          child: Align(
            alignment: _above ? Alignment.bottomLeft : Alignment.topLeft,
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(8),
              clipBehavior: Clip.antiAlias,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: _maxMenuH),
                child: m.isEmpty
                    ? Padding(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 12),
                        child: Text('No match',
                            style: TextStyle(
                                fontSize: 12.5, color: Colors.grey.shade600)),
                      )
                    : ListView.builder(
                        controller: _scroll,
                        shrinkWrap: true,
                        padding: EdgeInsets.zero,
                        itemCount: m.length,
                        itemExtent: _rowH,
                        itemBuilder: (_, i) => _row(m[i], i == _hi),
                      ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _row(T o, bool highlighted) {
    final detail = widget.detailOf?.call(o) ?? '';
    // Commit on pointer DOWN, not on tap. A tap only completes on pointer UP —
    // and the press itself can pull focus off the text field, which hides the
    // menu and takes this row out of the tree before the up ever arrives. The
    // click then does nothing at all. Down cannot be raced that way.
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: Listener(
        behavior: HitTestBehavior.opaque,
        onPointerDown: (_) => _commit(o),
        child: Container(
          height: _rowH,
          color: highlighted ? _navy.withValues(alpha: 0.10) : null,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          // Detail sits UNDER the label, not beside it. A design row's detail is
          // "600x600 · 2 surfaces · 2 qualities · 235 boxes" — far too long to
          // share a line, and side by side it just overflows the menu.
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                widget.labelOf(o),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 13,
                    height: 1.15,
                    color: highlighted ? _navy : Colors.black87,
                    fontWeight:
                        highlighted ? FontWeight.w700 : FontWeight.w500),
              ),
              if (detail.isNotEmpty)
                Text(detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                        fontSize: 11,
                        height: 1.15,
                        color: Colors.grey.shade600)),
            ],
          ),
        ),
      ),
    );
  }
}

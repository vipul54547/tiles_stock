import 'package:flutter/foundation.dart'; // debugPrint
import '../main.dart';

class StockService {
  // Atomic add via DB function — prevents race conditions
  Future<bool> addStock({
    required String designId,
    required String stockistUUID,
    required int    quantity,
    required String pdfFilename,
    required String size,
    required String quality,
  }) async {
    try {
      await supabase.rpc('add_stock', params: {
        'p_design_id':    designId,
        'p_stockist_id':  stockistUUID,
        'p_quantity':     quantity,
        'p_pdf_filename': pdfFilename,
        'p_size':         size,
        'p_quality':      quality,
      });
      return true;
    } catch (e, st) {
      debugPrint('StockService.addStock failed (design $designId): $e\n$st');
      return false;
    }
  }

  // Atomic dispatch via DB function — checks stock before subtracting
  Future<bool> dispatchStock({
    required String designId,
    required String stockistUUID,
    required int    quantity,
    required String buyerName,
    required String notes,
  }) async {
    try {
      final result = await supabase.rpc('dispatch_stock', params: {
        'p_design_id':   designId,
        'p_stockist_id': stockistUUID,
        'p_quantity':    quantity,
        'p_buyer_name':  buyerName,
        'p_notes':       notes,
      });
      return result as bool? ?? false;
    } catch (e, st) {
      debugPrint('StockService.dispatchStock failed (design $designId): $e\n$st');
      return false;
    }
  }

  // Recount: set a design's stock to the physically-counted value, logged as an
  // adjustment. Returns TRUE on success, FALSE if not the owner.
  Future<bool> adjustStock({
    required String designId,
    required int    newQuantity,
    required String reason,
    required String note,
  }) async {
    try {
      final res = await supabase.rpc('adjust_stock', params: {
        'p_design_id':    designId,
        'p_new_quantity': newQuantity,
        'p_reason':       reason,
        'p_note':         note,
      });
      return res as bool? ?? false;
    } catch (e, st) {
      debugPrint('StockService.adjustStock failed (design $designId): $e\n$st');
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getStockHistory(String designId) async {
    try {
      final ins = await supabase
          .from('stock_in')
          .select()
          .eq('design_id', designId)
          .order('created_at', ascending: false);

      final outs = await supabase
          .from('dispatches')
          .select()
          .eq('design_id', designId)
          .order('created_at', ascending: false);

      final adjustments = await supabase
          .from('stock_adjustments')
          .select()
          .eq('design_id', designId)
          .order('created_at', ascending: false);

      final history = <Map<String, dynamic>>[];

      for (final s in ins) {
        history.add({
          'type':     'in',
          'quantity': s['quantity_added'],
          'date':     s['created_at'].toString().substring(0, 10),
          'note':     s['pdf_filename'] ?? '',
        });
      }
      for (final d in outs) {
        history.add({
          'type':     'out',
          'quantity': d['quantity_dispatched'],
          'date':     d['created_at'].toString().substring(0, 10),
          'note':     d['buyer_name'],
        });
      }
      for (final a in adjustments) {
        final delta  = (a['delta'] as num).toInt();
        final reason = (a['reason'] ?? '').toString();
        final note   = (a['note'] ?? '').toString();
        history.add({
          'type':     'adjust',
          'quantity': delta.abs(),
          'sign':     delta >= 0 ? '+' : '-',
          'date':     a['created_at'].toString().substring(0, 10),
          'note':     'Recount ${a['old_quantity']}→${a['new_quantity']}'
              '${reason.isNotEmpty ? ' · $reason' : ''}'
              '${note.isNotEmpty ? ' · $note' : ''}',
        });
      }

      history.sort((a, b) => (b['date'] as String).compareTo(a['date'] as String));
      return history;
    } catch (e, st) {
      debugPrint('StockService.getStockHistory failed (design $designId): $e\n$st');
      return [];
    }
  }
}

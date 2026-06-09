import 'package:flutter/material.dart';
import '../../services/stock_service.dart';

class StockHistoryScreen extends StatefulWidget {
  final String designId;
  final String designName;
  const StockHistoryScreen(
      {super.key, required this.designId, required this.designName});
  @override
  State<StockHistoryScreen> createState() => _State();
}

class _State extends State<StockHistoryScreen> {
  final _stockSvc = StockService();
  List<Map<String, dynamic>> _history = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final data = await _stockSvc.getStockHistory(widget.designId);
    setState(() { _history = data; _loading = false; });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(widget.designName, overflow: TextOverflow.ellipsis),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _history.isEmpty
              ? const Center(
                  child: Text('No stock history found',
                      style: TextStyle(color: Colors.grey)))
              : ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: _history.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final rec = _history[i];
                    final type = rec['type'];
                    // in = green +, out = red -, adjust = blue with its own sign.
                    final Color color;
                    final IconData icon;
                    final String sign;
                    if (type == 'in') {
                      color = Colors.green;
                      icon = Icons.add;
                      sign = '+';
                    } else if (type == 'out') {
                      color = Colors.red;
                      icon = Icons.remove;
                      sign = '-';
                    } else {
                      color = const Color(0xFF1565C0);
                      icon = Icons.fact_check_outlined;
                      sign = (rec['sign'] ?? '').toString();
                    }
                    return Card(
                      child: ListTile(
                        leading: CircleAvatar(
                          backgroundColor: color.withValues(alpha: 0.12),
                          child: Icon(icon, color: color),
                        ),
                        title: Text(
                          '$sign ${rec['quantity']} boxes',
                          style: TextStyle(
                            fontWeight: FontWeight.bold,
                            color: color,
                            fontSize: 16,
                          ),
                        ),
                        subtitle: Text(rec['note'] ?? ''),
                        trailing: Text(
                          rec['date'] ?? '',
                          style: const TextStyle(color: Colors.grey, fontSize: 12),
                        ),
                      ),
                    );
                  },
                ),
    );
  }
}

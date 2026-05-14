import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';

import 'package:flutter_staggered_grid_view/flutter_staggered_grid_view.dart';

import '../../models/tile_design.dart';

import '../../services/data_service.dart';

import '../../widgets/tile_card.dart';



class StockistDashboardScreen extends StatefulWidget {

  const StockistDashboardScreen({super.key});

  @override State<StockistDashboardScreen> createState() => _State();

}



const _qualities = ['Premium', 'Standard'];

const _qualityMeta = {
  'Premium': (icon: Icons.star_rounded,      bg: Color(0xFFFFF8E1), fg: Color(0xFFF9A825)),
  'Standard': (icon: Icons.verified_outlined, bg: Color(0xFFE3F2FD), fg: Color(0xFF1565C0)),
  'Both':     (icon: Icons.layers_outlined,   bg: Color(0xFFE8F5E9), fg: Color(0xFF2E7D32)),
};

class _State extends State<StockistDashboardScreen> {

  final DataService _service = MockDataService();

  List<TileDesign> _designs = [];

  bool _loading = true;

  final String _myStockistId = '001';

  final Set<String> _selectedQualities = {};

  List<TileDesign> get _filtered => _selectedQualities.isEmpty
      ? _designs
      : _designs.where((d) => _selectedQualities.contains(d.quality)).toList();

  @override

  void initState() { super.initState(); _load(); }



  Future<void> _load() async {

    final data = await _service.getDesignsByStockist(_myStockistId);

    setState(() { _designs = data; _loading = false; });

  }

  Widget _buildQualityFilter() {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.05), blurRadius: 4, offset: const Offset(0, 2))],
      ),
      child: Row(
        children: _qualities.map((q) {
          final m = _qualityMeta[q]!;
          final selected = _selectedQualities.contains(q);
          return Expanded(
            child: GestureDetector(
              onTap: () => setState(() {
                if (selected) { _selectedQualities.remove(q); }
                else { _selectedQualities.add(q); }
              }),
              child: Container(
                margin: const EdgeInsets.only(right: 6),
                padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
                decoration: BoxDecoration(
                  color: selected ? m.fg : m.bg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: m.fg, width: selected ? 2 : 1),
                  boxShadow: selected
                      ? [BoxShadow(color: m.fg.withValues(alpha: 0.22), blurRadius: 4, offset: const Offset(0, 2))]
                      : [],
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(m.icon, size: 12, color: selected ? Colors.white : m.fg),
                    const SizedBox(width: 3),
                    Text(q,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: selected ? Colors.white : m.fg,
                        )),
                  ],
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }



  @override

  Widget build(BuildContext context) {

    return Scaffold(

      appBar: AppBar(

        title: const Text('My Stock Dashboard'),

        actions: [

          IconButton(

            icon: const Icon(Icons.notifications_outlined),

            onPressed: () => context.push('/stockist/inquiries'),

          ),

          IconButton(

            icon: const Icon(Icons.logout),

            onPressed: () => context.go('/login'),

          ),

        ],

      ),

      floatingActionButton: FloatingActionButton.extended(

        onPressed: () => context.push('/stockist/stock/add'),

        icon: const Icon(Icons.add),

        label: const Text('Add Stock'),

        backgroundColor: const Color(0xFF1B4F72),

        foregroundColor: Colors.white,

      ),

      body: _loading

          ? const Center(child: CircularProgressIndicator())

          : Column(children: [

        Container(

          color: const Color(0xFF1B4F72).withValues(alpha: 0.05),

          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),

          child: Row(

            mainAxisAlignment: MainAxisAlignment.spaceAround,

            children: [

              _stat('Total Designs', '${_designs.length}'),

              _stat('Total Boxes',

                  '${_designs.fold(0, (s, d) => s + d.boxQuantity)}'),

              _stat('Stockist ID', '#$_myStockistId'),

            ],

          ),

        ),

        _buildQualityFilter(),

        Expanded(

          child: _filtered.isEmpty
              ? const Center(
                  child: Text('No designs for selected quality',
                      style: TextStyle(color: Colors.grey)))
              : MasonryGridView.count(

            padding: const EdgeInsets.all(12),

            crossAxisCount: 2,

            crossAxisSpacing: 12,

            mainAxisSpacing: 12,

            itemCount: _filtered.length,

            itemBuilder: (_, i) => TileCard(

              design: _filtered[i],

              onTap: () => context.push('/stockist/stock/edit/${_filtered[i].id}'),

            ),

          ),

        ),

      ]),

    );

  }



  Widget _stat(String label, String value) => Column(children: [

    Text(value, style: const TextStyle(fontSize: 20,

        fontWeight: FontWeight.bold, color: Color(0xFF1B4F72))),

    Text(label, style: const TextStyle(fontSize: 11, color: Colors.grey)),

  ]);

} 
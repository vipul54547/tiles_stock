import 'package:flutter_test/flutter_test.dart';
import 'package:tiles_stock/utils/dna_chains.dart';

void main() {
  test('hierarchical tags collapse into one breadcrumb under the root attribute',
      () {
    final map = buildDnaChainMap(const [
      DnaTag(valueId: 'emboss', label: 'Emboss', attribute: 'Punch', attrSort: 1),
      DnaTag(valueId: 'wave', label: 'Wave', attribute: 'Punch Type',
          parentValueId: 'emboss', attrSort: 2),
      DnaTag(valueId: 'water', label: 'Water Punch', attribute: 'Punch Type',
          parentValueId: 'wave', attrSort: 2),
    ]);
    expect(map.keys.toList(), ['Punch']);
    expect(map['Punch'], ['Emboss › Wave › Water Punch']);
  });

  test('a flat multi-value attribute lists each value (option a)', () {
    final map = buildDnaChainMap(const [
      DnaTag(valueId: 'w', label: 'White', attribute: 'Colour', attrSort: 5, valSort: 1),
      DnaTag(valueId: 'b', label: 'Black', attribute: 'Colour', attrSort: 5, valSort: 2),
    ]);
    expect(map['Colour'], ['White', 'Black']);
  });

  test('two independent chains group under their own roots, attr-ordered', () {
    final map = buildDnaChainMap(const [
      DnaTag(valueId: 'marble', label: 'Marble', attribute: 'Look Type', attrSort: 1),
      DnaTag(valueId: 'carara', label: 'Carara', attribute: 'Natural Name',
          parentValueId: 'marble', attrSort: 3),
      DnaTag(valueId: 'emboss', label: 'Emboss', attribute: 'Punch', attrSort: 2),
    ]);
    expect(map.keys.toList(), ['Look Type', 'Punch']);
    expect(map['Look Type'], ['Marble › Carara']);
    expect(map['Punch'], ['Emboss']);
  });

  test('a child whose parent is not tagged becomes its own root', () {
    final map = buildDnaChainMap(const [
      DnaTag(valueId: 'wave', label: 'Wave', attribute: 'Punch Type',
          parentValueId: 'emboss', attrSort: 2),
    ]);
    expect(map['Punch Type'], ['Wave']);
  });
}

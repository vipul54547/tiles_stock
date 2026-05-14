import 'package:flutter/material.dart';

class ReceivedInquiriesScreen extends StatelessWidget {
  const ReceivedInquiriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final mockInquiries = List.generate(8, (i) => {
      'company': 'ABC Builders ${i + 1}',
      'city': 'Damoh',
      'message': 'Interested in bulk order for 600x600 Matt tiles.',
      'date': '${10 - i} May 2026',
      'status': i < 2 ? 'new' : 'seen',
    });

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Received Inquiries'),
      ),
      body: ListView.separated(
        padding: const EdgeInsets.all(12),
        itemCount: mockInquiries.length,
        separatorBuilder: (_, __) => const SizedBox(height: 8),
        itemBuilder: (_, i) {
          final inq = mockInquiries[i];
          final isNew = inq['status'] == 'new';
          return Card(
            elevation: isNew ? 3 : 1,
            child: ListTile(
              leading: CircleAvatar(
                backgroundColor: isNew ? const Color(0xFF1B4F72) : Colors.grey[300],
                child: Icon(Icons.business,
                    color: isNew ? Colors.white : Colors.grey),
              ),
              title: Text(inq['company']!,
                  style: TextStyle(
                      fontWeight: isNew ? FontWeight.bold : FontWeight.normal)),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(inq['city']!),
                  Text(inq['message']!, maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 12)),
                ],
              ),
              trailing: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(inq['date']!,
                      style: const TextStyle(fontSize: 11, color: Colors.grey)),
                  if (isNew)
                    Container(
                      margin: const EdgeInsets.only(top: 4),
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                          color: Colors.red,
                          borderRadius: BorderRadius.circular(10)),
                      child: const Text('NEW',
                          style: TextStyle(color: Colors.white, fontSize: 9)),
                    ),
                ],
              ),
              isThreeLine: true,
            ),
          );
        },
      ),
    );
  }
}

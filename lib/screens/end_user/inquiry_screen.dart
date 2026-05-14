import 'package:flutter/material.dart';

class InquiryScreen extends StatefulWidget {
  final String stockistId;
  final String designId;
  final String? preFilledMessage;
  const InquiryScreen({super.key, required this.stockistId, required this.designId, this.preFilledMessage});
  @override State<InquiryScreen> createState() => _InquiryScreenState();
}

class _InquiryScreenState extends State<InquiryScreen> {
  final _msgCtrl = TextEditingController();
  bool _sending = false;
  bool _sent = false;

  @override
  void initState() {
    super.initState();
    if (widget.preFilledMessage != null) {
      _msgCtrl.text = widget.preFilledMessage!;
    }
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    super.dispose();
  }

  void _send() async {
    setState(() => _sending = true);
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = true;
    });
    await Future.delayed(const Duration(milliseconds: 1500));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: const Text('Send Inquiry'),
      ),
      body: _sent ? _buildSuccess() : _buildForm(),
    );
  }

  Widget _buildSuccess() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: Colors.green.shade50,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.check_circle_outline_rounded,
                  size: 64, color: Colors.green.shade600),
            ),
            const SizedBox(height: 20),
            const Text(
              'Inquiry Sent Successfully!',
              style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text(
              'Your inquiry has been sent to Stockist #${widget.stockistId}.',
              style: const TextStyle(color: Colors.grey, fontSize: 14),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 24),
            const Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 10),
                Text('Redirecting back…',
                    style: TextStyle(color: Colors.grey, fontSize: 13)),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildForm() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Stockist info card
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Stockist ID: ${widget.stockistId}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  const Text(
                    'Your company details will be shared with the stockist.',
                    style: TextStyle(color: Colors.grey, fontSize: 12),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          const Text('Message (optional)',
              style: TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          TextField(
            controller: _msgCtrl,
            maxLines: 5,
            decoration: const InputDecoration(
              hintText: 'E.g. I need 100 boxes of this design...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 8),
          const Text('You have 8 inquiries remaining today',
              style: TextStyle(color: Colors.grey, fontSize: 12)),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _sending ? null : _send,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF1B4F72),
                foregroundColor: Colors.white,
              ),
              child: _sending
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2.5),
                    )
                  : const Text('Send Inquiry', style: TextStyle(fontSize: 16)),
            ),
          ),
        ],
      ),
    );
  }
}

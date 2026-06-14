import 'package:url_launcher/url_launcher.dart';
import '../config/app_config.dart';
import '../main.dart';

/// Opens a WhatsApp chat with the Tiles Stock team — the real message lands
/// there and auto-captures the buyer's number (better than a form) — and,
/// best-effort, logs a help request + notifies the team in-app so there's a
/// record even if the WhatsApp message never arrives.
///
/// Reusable: the guest logout-rescue dialog and a general "Need help?" entry
/// both call this. See project_buyer_onboarding_funnel.
Future<void> contactSupport({
  String ref = '',
  String message =
      'Hi Tiles Stock team, I need help with my account / keeping my suppliers.',
}) async {
  // Background record + team notification — never blocks opening WhatsApp.
  try {
    await supabase
        .rpc('log_help_request', params: {'p_ref': ref, 'p_context': message});
  } catch (_) {}
  final text = ref.isEmpty ? message : '$message (Ref: $ref)';
  final uri = Uri.parse(
      'https://wa.me/${AppConfig.supportWhatsApp}?text=${Uri.encodeComponent(text)}');
  await launchUrl(uri, mode: LaunchMode.externalApplication);
}

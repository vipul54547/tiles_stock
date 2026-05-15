import 'package:flutter/material.dart';

import 'package:go_router/go_router.dart';
import '../models/choice_state.dart';



class LoginScreen extends StatefulWidget {

  const LoginScreen({super.key});

  @override State<LoginScreen> createState() => _LoginScreenState();

}



class _LoginScreenState extends State<LoginScreen> {

  final _emailCtrl = TextEditingController();

  final _passCtrl = TextEditingController();

  bool _loading = false;



  void _login() async {

    setState(() => _loading = true);

    await Future.delayed(const Duration(seconds: 1));

    if (mounted) {
      final email = _emailCtrl.text.trim().toLowerCase();
      final mappedId = stockistTestAccounts[email];
      if (mappedId != null) {
        currentStockistId = mappedId;
        context.go('/stockist/dashboard');
      } else if (email.contains('stockist')) {
        currentStockistId = '001';
        context.go('/stockist/dashboard');
      } else if (email.contains('admin')) {
        context.go('/admin');
      } else {
        context.go('/home');
      }
    }

    setState(() => _loading = false);

  }



  @override

  Widget build(BuildContext context) {

    return Scaffold(

      backgroundColor: const Color(0xFFF5F5F5),

      body: SafeArea(

        child: SingleChildScrollView(

          padding: const EdgeInsets.all(24),

          child: Column(

            crossAxisAlignment: CrossAxisAlignment.start,

            children: [

              const SizedBox(height: 40),

              const Icon(Icons.grid_view_rounded, size: 48, color: Color(0xFF1B4F72)),

              const SizedBox(height: 16),

              const Text('Welcome Back',

                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),

              const Text('Sign in to Tiles Stock',

                  style: TextStyle(color: Colors.grey)),

              const SizedBox(height: 40),

              TextField(

                controller: _emailCtrl,

                decoration: const InputDecoration(

                  labelText: 'Email',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.email_outlined),

                ),

              ),

              const SizedBox(height: 16),

              TextField(

                controller: _passCtrl,

                obscureText: true,

                decoration: const InputDecoration(

                  labelText: 'Password',

                  border: OutlineInputBorder(),

                  prefixIcon: Icon(Icons.lock_outline),

                ),

              ),

              const SizedBox(height: 24),

              SizedBox(

                width: double.infinity,

                height: 50,

                child: ElevatedButton(

                  onPressed: _loading ? null : _login,

                  style: ElevatedButton.styleFrom(

                    backgroundColor: const Color(0xFF1B4F72),

                    foregroundColor: Colors.white,

                  ),

                  child: _loading

                      ? const CircularProgressIndicator(color: Colors.white)

                      : const Text('Login', style: TextStyle(fontSize: 16)),

                ),

              ),

              const SizedBox(height: 16),

              Center(

                child: TextButton(

                  onPressed: () => context.push('/register'),

                  child: const Text('New company? Register here'),

                ),

              ),

            ],

          ),

        ),

      ),

    );

  }

} 
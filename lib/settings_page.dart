import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

const String defaultServerAddress = 'https://duncandiesel.com/tracker';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _fleetIdController = TextEditingController();
  final _serverAddressController = TextEditingController();
  final _apiKeyController = TextEditingController();
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    _loadCurrentValues();
  }

  Future<void> _loadCurrentValues() async {
    final prefs = await SharedPreferences.getInstance();
    _fleetIdController.text = prefs.getString('fleet_id') ?? '';
    _serverAddressController.text =
        prefs.getString('server_address') ?? defaultServerAddress;
    _apiKeyController.text = prefs.getString('api_key') ?? '';
    setState(() => _loaded = true);
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('fleet_id', _fleetIdController.text.trim());

    final serverAddress = _serverAddressController.text.trim();
    await prefs.setString(
      'server_address',
      serverAddress.isEmpty ? defaultServerAddress : serverAddress,
    );

    // NOTE: stored in SharedPreferences for now, same simplification as the
    // rest of this prototype stage — this should move to secure storage
    // (Keychain-equivalent) before this becomes anything beyond a personal
    // testing build.
    await prefs.setString('api_key', _apiKeyController.text.trim());

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _fleetIdController.dispose();
    _serverAddressController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: !_loaded
          ? const Center(child: CircularProgressIndicator())
          : Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('Fleet ID', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _fleetIdController,
                    decoration: const InputDecoration(
                      hintText: 'e.g. AMB-123',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('Server Address',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _serverAddressController,
                    keyboardType: TextInputType.url,
                    decoration: InputDecoration(
                      hintText: defaultServerAddress,
                      border: const OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  const Text('API Key', style: TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  TextField(
                    controller: _apiKeyController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      hintText: 'Required to authenticate with the server',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ElevatedButton(
                    onPressed: _save,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(vertical: 12.0),
                      child: Text('Save'),
                    ),
                  ),
                ],
              ),
            ),
    );
  }
}

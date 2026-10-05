import 'package:flutter/material.dart';

import '../auth/auth_api.dart';
import '../auth/models/user.dart';
import '../call/call_controller.dart';
import '../live/live_location_client.dart';
import '../map/map_painter.dart';

/// Admin screen listing employees; only those currently online can be called.
class CallsScreen extends StatefulWidget {
  const CallsScreen({
    super.key,
    required this.token,
    required this.client,
    required this.call,
    this.onSignOut,
  });

  final String token;
  final LiveLocationClient client;
  final CallController call;
  final VoidCallback? onSignOut;

  @override
  State<CallsScreen> createState() => _CallsScreenState();
}

class _CallsScreenState extends State<CallsScreen> {
  final _api = AuthApi();
  List<Employee>? _employees;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final list = await _api.employees(widget.token);
      if (!mounted) return;
      setState(() {
        _employees = list;
        _error = null;
      });
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Call employees'),
        backgroundColor: Colors.white,
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _load,
          ),
          if (widget.onSignOut != null)
            IconButton(
              tooltip: 'Sign out',
              icon: const Icon(Icons.logout_rounded, color: GColors.redDark),
              onPressed: widget.onSignOut,
            ),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([widget.client, widget.call]),
        builder: (context, _) => _body(),
      ),
    );
  }

  Widget _body() {
    final employees = _employees;
    if (employees == null) {
      return _error == null
          ? const Center(child: CircularProgressIndicator())
          : Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    TextButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              ),
            );
    }
    if (employees.isEmpty) {
      return const Center(child: Text('No employees yet'));
    }

    final connected = widget.client.state == LiveConnection.connected;
    final sorted = [...employees]
      ..sort((a, b) {
        final byOnline = (widget.client.isOnline(b.id) ? 1 : 0) - (widget.client.isOnline(a.id) ? 1 : 0);
        return byOnline != 0 ? byOnline : a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });

    return Column(
      children: [
        if (!connected)
          const MaterialBanner(
            content: Text('Not connected to the server. Calls are unavailable.'),
            actions: [SizedBox.shrink()],
          ),
        Expanded(
          child: RefreshIndicator(
            onRefresh: _load,
            child: ListView.separated(
              physics: const AlwaysScrollableScrollPhysics(),
              itemCount: sorted.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (context, i) {
                final e = sorted[i];
                final online = widget.client.isOnline(e.id);
                final canCall = online && widget.call.isIdle;
                return ListTile(
                  leading: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      CircleAvatar(
                        backgroundColor: online ? const Color(0xFFE8F0FE) : const Color(0xFFF1F3F4),
                        child: Text(
                          e.name.characters.first.toUpperCase(),
                          style: TextStyle(color: online ? GColors.blue : GColors.textMuted),
                        ),
                      ),
                      Positioned(
                        right: -1,
                        bottom: -1,
                        child: Container(
                          width: 12,
                          height: 12,
                          decoration: BoxDecoration(
                            color: online ? GColors.green : GColors.wall,
                            shape: BoxShape.circle,
                            border: Border.all(color: Colors.white, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  title: Text(e.name),
                  subtitle: Text(online ? 'Online' : 'Offline'),
                  trailing: IconButton.filled(
                    tooltip: online ? 'Call ${e.name}' : '${e.name} is offline',
                    style: IconButton.styleFrom(
                      backgroundColor: GColors.green,
                      disabledBackgroundColor: const Color(0xFFE8EAED),
                    ),
                    icon: const Icon(Icons.call),
                    onPressed: canCall
                        ? () => widget.call.startCall(userId: e.id, name: e.name)
                        : null,
                  ),
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}

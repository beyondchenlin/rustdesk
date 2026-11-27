import 'dart:convert';

import 'package:flutter/material.dart';

import '../../common.dart';
import '../../models/platform_model.dart';

class BkRemoteUpdateChannelNotice extends StatefulWidget {
  const BkRemoteUpdateChannelNotice({super.key});

  @override
  State<BkRemoteUpdateChannelNotice> createState() =>
      _BkRemoteUpdateChannelNoticeState();
}

class _BkRemoteUpdateChannelNoticeState
    extends State<BkRemoteUpdateChannelNotice> {
  late final Future<bool> _configured = _load();

  Future<bool> _load() async {
    final raw = await bind.mainGetCommon(key: 'bk-update-channel');
    final channel = jsonDecode(raw);
    if (channel is! Map<String, dynamic> || channel['configured'] is! bool) {
      throw const FormatException('Invalid software update channel status');
    }
    return channel['configured'] as bool;
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<bool>(
        future: _configured,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done ||
              snapshot.data == true) {
            return const SizedBox.shrink();
          }
          final message = snapshot.hasError
              ? 'Unable to read the software update channel'
              : 'The software update channel is not configured. Contact your administrator for a signed installer.';
          return Padding(
            padding: const EdgeInsets.only(top: 4, bottom: 4),
            child: Text(translate(message),
                style: Theme.of(context).textTheme.bodySmall),
          );
        },
      );
}

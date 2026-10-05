import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Where RomDrop is and how this device identifies itself there. The device
/// token is kept apart from this, in secure storage.
class RomDropConnection {
  final String baseUrl;
  final String deviceId;
  final String deviceName;

  /// SHA-256 of the server certificate the user accepted; null when the
  /// certificate is publicly trusted or the address is plain HTTP.
  final String? certificateFingerprint;

  const RomDropConnection({
    required this.baseUrl,
    this.deviceId = '',
    this.deviceName = '',
    this.certificateFingerprint,
  });

  bool get encrypted => baseUrl.startsWith('https://');

  Map<String, dynamic> toJson() => {
        'baseUrl': baseUrl,
        'deviceId': deviceId,
        'deviceName': deviceName,
        if (certificateFingerprint != null)
          'certificateFingerprint': certificateFingerprint,
      };

  factory RomDropConnection.fromJson(Map<String, dynamic> json) =>
      RomDropConnection(
        baseUrl: json['baseUrl'] as String,
        deviceId: json['deviceId'] as String? ?? '',
        deviceName: json['deviceName'] as String? ?? '',
        certificateFingerprint: json['certificateFingerprint'] as String?,
      );
}

/// Persists the RomDrop connection. RomDrop has its own device credential; it
/// shares nothing with the RetroArr source's API key.
class RomDropConnectionStore {
  RomDropConnectionStore(this._prefs, {FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ??
            // Same options as StorageService: both use one secure prefs file.
            const FlutterSecureStorage(
              aOptions: AndroidOptions(encryptedSharedPreferences: true),
            );

  static const _connectionKey = 'romdrop_connection';
  static const _tokenKey = 'romdrop:device_token';

  final SharedPreferences _prefs;
  final FlutterSecureStorage _secure;

  RomDropConnection? read() {
    final raw = _prefs.getString(_connectionKey);
    if (raw == null) return null;
    try {
      return RomDropConnection.fromJson(
          Map<String, dynamic>.from(jsonDecode(raw) as Map));
    } catch (e) {
      debugPrint('RomDrop: stored connection is unreadable: $e');
      return null;
    }
  }

  Future<String?> readToken() async {
    try {
      return await _secure.read(key: _tokenKey);
    } catch (e) {
      debugPrint('RomDrop: could not read the device token: $e');
      return null;
    }
  }

  Future<void> save(RomDropConnection connection, String token) async {
    await _secure.write(key: _tokenKey, value: token);
    await _prefs.setString(_connectionKey, jsonEncode(connection.toJson()));
  }

  /// Forgets the server and the credential on this device. The credential
  /// stays valid on the server until it is revoked there.
  Future<void> clear() async {
    await _prefs.remove(_connectionKey);
    await _secure.delete(key: _tokenKey);
  }
}

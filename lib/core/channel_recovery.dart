import 'dart:convert';
import 'dart:math';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

import 'channel_key_store.dart';
import 'channels.dart';
import 'identity.dart';

/// Portable encrypted recovery, independent of any server or device keystore.
/// Public parameters are fixed before expensive work to reject hostile imports.
class ChannelRecovery {
  static Future<String> encryptAsync(
    Map<String, dynamic> material,
    String password,
  ) => Isolate.run(() => encrypt(material, password));
  static Future<Map<String, dynamic>> decryptAsync(
    String file,
    String password,
  ) => Isolate.run(() => decrypt(file, password));
  static const memoryKiB = 65536;
  static const iterations = 3;
  static const maxFileBytes = 128 * 1024;
  static final _aad = Uint8List.fromList(
    utf8.encode('farvahartrends/channel-recovery/v1'),
  );
  static final _ownerAad = Uint8List.fromList(
    utf8.encode('farvahartrends/channel-owner-recovery/v2'),
  );
  static Future<String> encryptOwnerKitAsync(
    Map<String, dynamic> material,
    String password,
  ) => Isolate.run(() => encryptOwnerKit(material, password));
  static Future<Map<String, dynamic>> decryptOwnerKitAsync(
    String file,
    String password,
  ) => Isolate.run(() => _decrypt(file, password, ownerKit: true));

  static void _validateOwnerKit(Map<String, dynamic> material) {
    const fields = {'channel', 'recoveryIdentity', 'generation'};
    if (material.length != fields.length ||
        !material.keys.every(fields.contains) ||
        material['generation'] is! int ||
        material['generation'] < 1 ||
        material['generation'] > 9007199254740991) {
      throw const FormatException('Invalid owner recovery kit.');
    }
    final channel = SignedChannel.fromJson(
      Map<String, dynamic>.from(material['channel'] as Map),
    );
    final recovery = Identity.fromJson(
      Map<String, dynamic>.from(material['recoveryIdentity'] as Map),
    );
    if (!channel.recoverable || recovery.id != channel.recoveryId) {
      throw const FormatException('Recovery key does not match this channel.');
    }
  }

  static String encryptOwnerKit(
    Map<String, dynamic> material,
    String password,
  ) {
    validatePassword(password);
    _validateOwnerKit(material);
    return _encrypt(material, password, ownerKit: true);
  }

  static Uint8List _random(int count) {
    final random = Random.secure();
    return Uint8List.fromList(List.generate(count, (_) => random.nextInt(256)));
  }

  static void validatePassword(String password) {
    if (password.runes.length < 16 ||
        utf8.encode(password).length > 1024 ||
        password.runes.toSet().length < 6) {
      throw const FormatException(
        'Use at least 16 characters and several unrelated words.',
      );
    }
  }

  static Uint8List _key(String password, Uint8List salt) {
    final bytes = Uint8List.fromList(utf8.encode(password));
    try {
      final generator = Argon2BytesGenerator()
        ..init(
          Argon2Parameters(
            Argon2Parameters.ARGON2_id,
            salt,
            desiredKeyLength: 32,
            iterations: iterations,
            memory: memoryKiB,
            lanes: 1,
            version: Argon2Parameters.ARGON2_VERSION_13,
          ),
        );
      return generator.process(bytes);
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  static String encrypt(Map<String, dynamic> material, String password) {
    validatePassword(password);
    ChannelKeyStore.validateEntry(
      Map<String, dynamic>.from(material['entry'] as Map),
    );
    if ((material['entry'] as Map)['role'] != 'owner') {
      throw const FormatException('Only owners can create a recovery file.');
    }
    return _encrypt(material, password);
  }

  static String _encrypt(
    Map<String, dynamic> material,
    String password, {
    bool ownerKit = false,
  }) {
    final salt = _random(16),
        nonce = _random(12),
        plain = Uint8List.fromList(utf8.encode(jsonEncode(material)));
    final key = _key(password, salt);
    try {
      if (plain.length > 64 * 1024) {
        throw const FormatException('Recovery material is too large.');
      }
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          true,
          AEADParameters(
            KeyParameter(key),
            128,
            nonce,
            ownerKit ? _ownerAad : _aad,
          ),
        );
      final encrypted = cipher.process(plain);
      return jsonEncode({
        'version': ownerKit ? 2 : 1,
        'kind': ownerKit ? 'channel-owner-recovery' : 'channel-recovery',
        'kdf': 'argon2id-1.3',
        'memoryKiB': memoryKiB,
        'iterations': iterations,
        'lanes': 1,
        'cipher': 'aes-256-gcm',
        'salt': base64Encode(salt),
        'nonce': base64Encode(nonce),
        'ciphertext': base64Encode(encrypted),
      });
    } finally {
      key.fillRange(0, key.length, 0);
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Map<String, dynamic> decrypt(String file, String password) =>
      _decrypt(file, password);

  static Map<String, dynamic> _decrypt(
    String file,
    String password, {
    bool ownerKit = false,
  }) {
    Uint8List? key, plain;
    try {
      if (utf8.encode(file).length > maxFileBytes ||
          utf8.encode(password).length > 1024) {
        throw const FormatException();
      }
      final json = jsonDecode(file);
      const fields = {
        'version',
        'kind',
        'kdf',
        'memoryKiB',
        'iterations',
        'lanes',
        'cipher',
        'salt',
        'nonce',
        'ciphertext',
      };
      if (json is! Map<String, dynamic> ||
          json.length != fields.length ||
          !json.keys.every(fields.contains) ||
          json['version'] is! int ||
          json['version'] != (ownerKit ? 2 : 1) ||
          json['kind'] !=
              (ownerKit ? 'channel-owner-recovery' : 'channel-recovery') ||
          json['kdf'] != 'argon2id-1.3' ||
          json['memoryKiB'] != memoryKiB ||
          json['iterations'] != iterations ||
          json['lanes'] != 1 ||
          json['cipher'] != 'aes-256-gcm') {
        throw const FormatException();
      }
      final salt = base64Decode(json['salt'] as String),
          nonce = base64Decode(json['nonce'] as String),
          encrypted = base64Decode(json['ciphertext'] as String);
      if (salt.length != 16 ||
          nonce.length != 12 ||
          encrypted.length < 16 ||
          encrypted.length > 64 * 1024 + 16 ||
          base64Encode(salt) != json['salt'] ||
          base64Encode(nonce) != json['nonce'] ||
          base64Encode(encrypted) != json['ciphertext']) {
        throw const FormatException();
      }
      key = _key(password, salt);
      final cipher = GCMBlockCipher(AESEngine())
        ..init(
          false,
          AEADParameters(
            KeyParameter(key),
            128,
            nonce,
            ownerKit ? _ownerAad : _aad,
          ),
        );
      plain = cipher.process(encrypted);
      final material = jsonDecode(utf8.decode(plain));
      if (ownerKit) {
        if (material is! Map<String, dynamic>) throw const FormatException();
        _validateOwnerKit(material);
        return material;
      }
      if (material is! Map<String, dynamic> ||
          material.length != 3 ||
          material['entry'] is! Map ||
          material['sequence'] is! int ||
          material['sequence'] < 0 ||
          material['sequence'] > 9007199254740991 ||
          (material['policy'] != null && material['policy'] is! Map)) {
        throw const FormatException();
      }
      final entry = Map<String, dynamic>.from(material['entry'] as Map);
      ChannelKeyStore.validateEntry(entry);
      if (entry['role'] != 'owner') throw const FormatException();
      return material;
    } catch (_) {
      throw const FormatException('Recovery file or password is incorrect.');
    } finally {
      key?.fillRange(0, key.length, 0);
      plain?.fillRange(0, plain.length, 0);
    }
  }
}

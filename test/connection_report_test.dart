import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:persian_trend/core/connection_report.dart';

void main() {
  test('manual report retains useful stages without private snapshot data', () {
    final report = connectionReport(
      snapshot: {
        'identityId': 'a' * 64,
        'connectedCount': 1,
        'activeTransportCounts': {'overlay': 1, 'lan': 0, 'unknown': 7},
        'peers': [
          {'host': '203.0.113.22', 'name': 'Private peer'},
        ],
        'channels': ['Private subscription'],
        'bulletins': ['Private news'],
        'privateKey': 'SECRET KEY',
        'overlay': {
          'state': 'discovering',
          'discoveryStage': 'bootstrapping',
          'dhtOnline': false,
          'dhtFirewalled': true,
          'cachedRoutingCount': 24,
          'cachedPeerCount': 3,
          'reachableHelper': false,
          'discoveryRefreshes': 2,
          'ownContact': {'host': '203.0.113.23'},
          'error': 'Connection to 203.0.113.22 failed',
        },
      },
      device: {
        'appVersion': '0.8.3',
        'network': 'cellular',
        'internetValidated': true,
        'screenOn': false,
        'isLocked': true,
        'bootId': 'PRIVATE BOOT',
        'activeNetworkEpoch': 'PRIVATE INTERFACE',
      },
      running: true,
      activeMode: true,
      deliveryMode: 'allNetworks',
    );
    expect(report['connectionId'], 'a' * 12);
    expect(report['network'], 'cellular');
    expect(report['connectedCount'], 1);
    expect((report['overlay'] as Map)['dhtOnline'], false);
    expect((report['overlay'] as Map)['discoveryStage'], 'bootstrapping');
    final encoded = jsonEncode(report);
    for (final secret in [
      '203.0.113',
      'Private',
      'SECRET',
      'PRIVATE',
      'a' * 64,
      'ownContact',
      'unknown',
    ]) {
      expect(encoded, isNot(contains(secret)));
    }
  });

  test('malformed values cannot enter report through diagnostic fields', () {
    final report = connectionReport(
      snapshot: {
        'identityId': 'BAD ID',
        'connectedCount': -1,
        'activeTransportCounts': {'overlay': 99999999, 'lan': 'private'},
        'overlay': {
          'state': 'private text',
          'discoveryStage': 'private text',
          'dhtOnline': 'private text',
          'cachedRoutingCount': -2,
          'discoveryRefreshes': 99999999,
          'error': 'worklet_unresponsive',
        },
      },
      device: {'appVersion': 'private text', 'network': '192.168.0.1'},
      running: false,
      activeMode: false,
      deliveryMode: 'private text',
    );
    expect(report.containsKey('connectionId'), false);
    expect(report.containsKey('connectedCount'), false);
    expect((report['transports'] as Map)['overlay'], 8);
    expect((report['overlay'] as Map)['discoveryRefreshes'], 1000000);
    expect((report['overlay'] as Map)['error'], 'worklet_unresponsive');
    expect(jsonEncode(report), isNot(contains('private')));
    expect(jsonEncode(report), isNot(contains('192.168.0.1')));
  });
}

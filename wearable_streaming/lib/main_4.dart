// ignore_for_file: avoid_print

import 'dart:io';

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:polar/polar.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:sembast/sembast.dart';
import 'package:sembast/sembast_io.dart';
import 'package:sembast/utils/sembast_import_export.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';

void main() => runApp(const HRApp());

/// This HR Monitor is a direct copy of main_3.dart but also supports saving
/// HR data persistently on the phone using the "sembast" database.
class HRApp extends StatelessWidget {
  const HRApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(home: HRHomePage());
}

class HRHomePage extends StatefulWidget {
  const HRHomePage({super.key});

  @override
  State<HRHomePage> createState() => _HRHomePageState();
}

class _HRHomePageState extends State<HRHomePage> {
  final HRMonitor monitor = StatefulPolarHRMonitor('B36B5B21');

  @override
  void initState() {
    super.initState();
    monitor.init();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Polar HR Monitor')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: <Widget>[
            StreamBuilder<DeviceState>(
              stream: monitor.stateChange,
              builder: (context, snapshot) =>
                  Text('Polar [${monitor.identifier}] - ${monitor.state.name}'),
            ),
            const Text('Your heart rate is:'),
            StreamBuilder<int>(
                stream: monitor.heartbeat,
                builder: (context, snapshot) {
                  var displayText = 'unknown';
                  if (snapshot.hasData) displayText = '${snapshot.data}';
                  return Text(
                    displayText,
                    style: Theme.of(context).textTheme.headlineMedium,
                  );
                }),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          if (monitor.isRunning) {
            monitor.stop();
          } else {
            monitor.start();
          }
        },
        tooltip: 'Start/Stop HR Monitor',
        child: StreamBuilder<DeviceState>(
          stream: monitor.stateChange,
          builder: (context, snapshot) => (monitor.isRunning)
              ? const Icon(Icons.stop)
              : const Icon(Icons.play_arrow),
        ),
      ),
    );
  }
}

/// A Heart Rate (HR) Monitor interface.
///
/// The [stateChange] streams state changes of this monitor.
/// The [heartbeat] stream emits heart rate events as [int].
/// Can be started and stopped via the [start] and [stop] commands.
abstract class HRMonitor {
  /// The identifier of this monitor.
  String get identifier;

  /// The state of this monitor.
  DeviceState get state;

  /// The stream of state changes of this monitor.
  Stream<DeviceState> get stateChange;

  /// The stream of heartbeat measures from this HR monitor.
  Stream<int> get heartbeat;

  /// Has this monitor been started via the [start] command?
  bool get isRunning;

  /// Initialize this HR monitor.
  Future<void> init();

  /// Start this HR monitor.
  void start();

  /// Stop this HR monitor.
  void stop();
}

/// An enumeration of know device states.
enum DeviceState {
  unknown,
  initialized,
  connecting,
  connected,
  sampling,
  disconnected,
}

/// A stateful Polar Heart Rate (HR) Monitor where you can listen to
/// [stateChange] events.
class StatefulPolarHRMonitor implements HRMonitor {
  StreamSubscription<PolarHrData>? _subscription;
  final String _identifier;
  final polar = Polar();
  late Storage storage;

  // The follow code controls the state management and stream of state changes.
  final _controller = StreamController<int>.broadcast();

  final StreamController<DeviceState> _stateChangeController =
      StreamController.broadcast();
  DeviceState _state = DeviceState.unknown;

  set state(DeviceState state) {
    print('The device with id $identifier is ${state.name}.');
    _state = state;
    _stateChangeController.add(state);
  }

  @override
  DeviceState get state => _state;

  @override
  Stream<DeviceState> get stateChange => _stateChangeController.stream;

  @override
  String get identifier => _identifier;

  @override
  Stream<int> get heartbeat => _controller.stream;

  StatefulPolarHRMonitor(this._identifier) {
    storage = Storage(this);
  }

  @override
  Future<void> init() async {
    if (!(await hasPermissions)) await requestPermissions();

    polar.batteryLevel.listen((e) => print('Battery: ${e.level}'));
    polar.deviceConnecting.listen((_) => state = DeviceState.connecting);
    polar.deviceConnected.listen((_) => state = DeviceState.connected);
    polar.deviceDisconnected.listen((_) => state = DeviceState.disconnected);

    state = DeviceState.initialized;

    await storage.init();
    await polar.connectToDevice(identifier);
  }

  /// Do we have the required Bluetooth permissions?
  Future<bool> get hasPermissions async =>
      await Permission.bluetoothScan.isGranted &&
      await Permission.bluetoothConnect.isGranted;

  /// Request the required Bluetooth permissions.
  Future<void> requestPermissions() async => await [
        Permission.bluetooth,
        Permission.bluetoothScan,
        Permission.bluetoothConnect,
      ].request();

  @override
  bool get isRunning => state == DeviceState.sampling;

  @override
  void start() {
    if (state == DeviceState.connected) {
      _subscription =
          polar.startHrStreaming(identifier).listen((PolarHrData event) {
        _controller.add(event.samples.first.hr);
      });
      state = DeviceState.sampling;
    }
  }

  @override
  void stop() {
    _subscription?.cancel();
    state = DeviceState.connected;
  }
}

/// Responsible for storing HR data to a Sembast database.
class Storage {
  static const String DB_NAME = 'hr_monitor';
  HRMonitor _monitor;
  var _database;
  StoreRef? _store;

  /// The path to the phone's application folder.
  Directory? dir;

  /// Initialize this storage by identifying which [_monitor] is should save
  /// data for.
  Storage(this._monitor);

  /// Initialize the storage by opening the database and listening to HR events.
  Future<void> init() async {
    print('Initializing storage, id: ${_monitor.identifier}');

    // Get the application documents directory
    dir = await getApplicationDocumentsDirectory();
    if (dir == null) {
      print('WARNING - could not create database. Data is not saved....');
    } else {
      // Make sure it exists
      await dir?.create(recursive: true);
      // Build the database path
      var path = join(dir!.path, '$DB_NAME.db');
      // Open the database
      _database = await databaseFactoryIo.openDatabase(path);

      // Create a store with the name of the identifier of the monitor and which
      // can hold maps indexed by an int.
      _store = intMapStoreFactory.store(_monitor.identifier);

      // Create a JSON object with the timestamp and HR:
      //   {timestamp: 1699880580494, hr: 57}
      Map<String, int> json = {};

      // Listen to the monitor's HR event and add them to the store.
      _monitor.heartbeat.listen((int hr) {
        // Timestamp the HR reading.
        json['timestamp'] = DateTime.now().millisecondsSinceEpoch;
        json['hr'] = hr;

        // Add the json record to the database
        _store?.add(_database, json);
      });

      // Create a dumper to save the data on a regular basis
      DumpManager(this).start();
    }
  }

  /// The total number of HR samples collected in the database.
  ///
  /// Example use:
  ///    count().then((count) => print('>> size: $count'));
  ///
  /// Returns -1 if unknown.
  Future<int> count() async => await _store?.count(_database) ?? -1;

  /// Get the list of json objects which has not yet been uploaded.
  // TODO - implement this getJsonToUpload() method.
  Future<List<Map<String, int>>> getJsonToUpload() async => [{}];

  /// Dump the database to a text file with JSON data.
  /// The name of the file is the same as the database with extension '.json'.
  Future<void> dump() async {
    print('Starting to dump database');
    int count = await this.count();

    // Export db, but only this store.
    Map<String, Object?> data =
        await exportDatabase(_database, storeNames: [_monitor.identifier]);

    // Convert the JSON map to a string representation.
    String dataAsJson = json.encode(data);
    // Build the file path and write the data
    var path = join(dir!.path, '$DB_NAME.json');
    await File(path).writeAsString(dataAsJson);
    print("Database dumped in file '$path'. "
        'Total $count records successfully written to file.');
  }
}

/// A manager that dumps the database to a JSON file on regular basis.
class DumpManager {
  Storage storage;
  Timer? dumper;

  /// Create an [DumpManager] which can upload data stored in the database.
  DumpManager(this.storage);

  /// Start dumping the db every 10 minutes.
  void start() {
    dumper = Timer.periodic(
        const Duration(minutes: 1), (_) async => await storage.dump());
  }

  /// Stop dumping.
  void stop() => dumper?.cancel();
}

/// A manager that collects data from [storage] which has not been uploaded
/// yet and uploads this on regular basis.
class UploadManager {
  Storage storage;
  Timer? uploadTimer;

  /// Create an [UploadManager] which can upload data stored in [storage].
  UploadManager(this.storage);

  /// Start uploading every 10 minutes.
  void startUpload() {
    uploadTimer = Timer.periodic(const Duration(minutes: 10), (timer) async {
      var dataToUpload = await storage.getJsonToUpload();
      print('Uploading ${dataToUpload.length} json objects...');
    });
  }

  /// Stop uploading.
  void stopUpload() => uploadTimer?.cancel();
}

import 'dart:async';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:isolate_manager/src/isolate_manager_controller/web.dart'
    if (dart.library.io) 'isolate_manager_controller/stub.dart';

/// This method only use to create a custom isolate.
class IsolateManagerController<R, P> {
  /// This method only use to create a custom isolate.
  ///
  /// The [params] is a default parameter of a custom isolate function.
  /// `onDispose` will be called when the controller is disposed.
  IsolateManagerController(
    dynamic params, {
    void Function()? onDispose,
  }) : _delegate = IsolateManagerControllerImpl<R, P>(
          params,
          onDispose: onDispose,
        );
  final IsolateManagerControllerImpl<R, P> _delegate;

  /// Mark the isolate as initialized.
  ///
  /// This method is automatically applied when using `IsolateManagerFunction.customFunction`
  /// and `IsolateManagerFunction.workerFunction`.
  void initialized() => _delegate.initialized();

  /// Close this `IsolateManagerController`.
  Future<void> close() => _delegate.close();

  /// Get initial parameters when you create the IsolateManager.
  dynamic get initialParams => _delegate.initialParams;

  /// This parameter is only used for Isolate. Use to listen for values from the main application.
  Stream<P> get onIsolateMessage => _delegate.onIsolateMessage;

  /// Get direct access to the raw Worker global scope for advanced control.
  /// Only available in Web Worker environment.
  ///
  /// Use this when you need complete control over Worker communication
  /// and want to bypass all IsolateManager abstractions.
  dynamic get rawWorkerScope => _delegate.rawWorkerScope;

  /// Set a custom message handler that receives all raw messages.
  /// This bypasses the normal message processing pipeline.
  ///
  /// [handler] will receive the raw MessageEvent from the Worker.
  /// Return true to also process the message through normal pipeline,
  /// return false to stop further processing.
  void setRawMessageHandler(bool Function(dynamic event) handler) =>
      _delegate.setRawMessageHandler(handler);

  /// Send raw message directly through Worker's postMessage.
  /// This bypasses all IsolateManager message formatting and processing.
  ///
  /// [data] will be sent as-is through Worker.postMessage()
  void sendRawMessage(dynamic data) => _delegate.sendRawMessage(data);

  /// Send values from Isolate to the main application (to `onMessage`).
  void sendResult(R result) => _delegate.sendResult(result);

  /// Send the `Exception` to the main app.
  void sendResultError(IsolateException exception) =>
      _delegate.sendResultError(exception);
}

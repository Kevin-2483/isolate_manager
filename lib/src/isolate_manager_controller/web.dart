import 'dart:async';
import 'dart:convert';
import 'dart:js_interop';

import 'package:isolate_manager/isolate_manager.dart';
import 'package:isolate_manager/src/base/isolate_contactor.dart';
import 'package:isolate_manager/src/utils/check_subtype.dart';
import 'package:web/web.dart';

/// This method only use to create a custom isolate.
class IsolateManagerControllerImpl<R, P>
    implements IsolateManagerController<R, P> {
  /// This method only use to create a custom isolate.
  ///
  /// The [params] is a default parameter of a custom isolate function.
  /// `onDispose` will be called when the controller is disposed.
  IsolateManagerControllerImpl(
    dynamic params, {
    void Function()? onDispose,
  }) : _delegate = params.runtimeType == DedicatedWorkerGlobalScope
            ? _IsolateManagerWorkerController<R, P>(
                params as DedicatedWorkerGlobalScope,
                onDispose: onDispose,
              )
            : IsolateContactorController<R, P>(params, onDispose: onDispose);

  /// Delegation of IsolateContactor.
  final IsolateContactorController<R, P> _delegate;

  /// Mark the isolate as initialized.
  ///
  /// This method is automatically applied when using `IsolateManagerFunction.customFunction`
  /// and `IsolateManagerFunction.workerFunction`.
  @override
  void initialized() => _delegate.initialized();

  /// Close this `IsolateManagerController`.
  @override
  Future<void> close() => _delegate.close();

  /// Get initial parameters when you create the IsolateManager.
  @override
  dynamic get initialParams => _delegate.initialParams;

  /// This parameter is only used for Isolate. Use to listen for values from the main application.
  @override
  Stream<P> get onIsolateMessage => _delegate.onIsolateMessage;

  /// Send values from Isolate to the main application (to `onMessage`).
  @override
  void sendResult(R result) => _delegate.sendResult(result);

  /// Send the `Exception` to the main app.
  @override
  void sendResultError(IsolateException exception) =>
      _delegate.sendResultError(exception);

  /// Get direct access to the raw Worker global scope for advanced control.
  /// Only available in Web Worker environment.
  @override
  dynamic get rawWorkerScope {
    if (_delegate is _IsolateManagerWorkerController<R, P>) {
      return _delegate.rawWorkerScope;
    }
    throw UnsupportedError(
        'rawWorkerScope is only available in Web Worker environment');
  }

  /// Set a custom message handler that receives all raw messages.
  @override
  void setRawMessageHandler(bool Function(dynamic event) handler) {
    if (_delegate is _IsolateManagerWorkerController<R, P>) {
      _delegate.setRawMessageHandler(handler);
    } else {
      throw UnsupportedError(
          'setRawMessageHandler is only available in Web Worker environment');
    }
  }

  /// Send raw message directly through Worker's postMessage.
  @override
  void sendRawMessage(dynamic data) {
    if (_delegate is _IsolateManagerWorkerController<R, P>) {
      _delegate.sendRawMessage(data);
    } else {
      throw UnsupportedError(
          'sendRawMessage is only available in Web Worker environment');
    }
  }
}

// TODO(lamnhan066): Find a way to test these methods because it only used by the compiled JS Worker.
// coverage:ignore-start
class _IsolateManagerWorkerController<R, P>
    implements IsolateContactorController<R, P> {
  _IsolateManagerWorkerController(this.self, {this.onDispose}) {
    // 保存原始的 onmessage 处理器
    _originalOnMessage = (MessageEvent event) {
      // --- 这是我们添加的核心修改 ---
      try {
        // 先调用自定义的原始处理器（如果有）
        if (_rawMessageHandler != null) {
          final shouldContinue = _rawMessageHandler!(event);
          if (!shouldContinue) {
            return; // 停止进一步处理
          }
        }

        // 正常的消息处理
        final rawData = event.data.dartify();
        dynamic processedData = rawData;

        // 检查接收到的原始数据是否为字符串
        if (rawData is String) {
          try {
            // 如果是字符串，尝试用 JSON 解码
            processedData = json.decode(rawData);
          } catch (e) {
            // 解码失败，说明它就是个普通字符串，不是JSON
            // 保持 processedData 为原始字符串，不做处理
            print(
                '[IsolateManager-Worker-Patch] Received a non-JSON string: $e');
          }
        }

        // 确保 ImType 逻辑仍然有效
        if (isImTypeSubtype<P>()) {
          processedData = ImType.wrap(processedData as Object);
        }

        // 将最终处理过的数据添加到流中
        _streamController.sink.add(processedData as P);
      } catch (e, s) {
        // 如果整个过程出错，将错误发送到流中
        _streamController.sink.addError(e, s);
      }
      // --- 核心修改结束 ---
    }.toJS;

    self.onmessage = _originalOnMessage;
  }

  final DedicatedWorkerGlobalScope self;
  final void Function()? onDispose;
  final _streamController = StreamController<P>.broadcast();
  // 新增字段
  late final JSFunction _originalOnMessage;
  bool Function(dynamic)? _rawMessageHandler;

  /// 获取原始 Worker 作用域
  dynamic get rawWorkerScope => self;

  /// 设置原始消息处理器
  void setRawMessageHandler(bool Function(dynamic event) handler) {
    _rawMessageHandler = handler;
  }

  /// 发送原始消息
  void sendRawMessage(dynamic data) {
    try {
      // 安全地转换 data 为 JSAny
      JSAny? jsData;
      if (data == null) {
        jsData = null; // 直接使用 null
      } else if (data is String) {
        jsData = data.toJS;
      } else if (data is num) {
        jsData = data.toJS;
      } else if (data is bool) {
        jsData = data.toJS;
      } else {
        // 对于其他类型，尝试转换为字符串
        jsData = data.toString().toJS;
      }
      self.postMessage(jsData);
    } catch (e) {
      // 如果所有转换都失败，发送错误信息
      self.postMessage('Error converting data to JS: $e'.toJS);
    }
  }

  /// 新增：直接设置 onmessage 处理器（完全绕过 IsolateManager）
  void setRawOnMessageHandler(JSFunction handler) {
    self.onmessage = handler;
  }

  /// 新增：恢复默认的 onmessage 处理器
  void restoreDefaultOnMessageHandler() {
    self.onmessage = _originalOnMessage;
  }

  @override
  Stream<P> get onIsolateMessage => _streamController.stream.cast();

  @override
  Object? get initialParams => null;

  /// Send result to the main app
  @override
  void sendResult(R m) {
    if (m is ImType) {
      self.postMessage(
        <String, Object?>{'type': 'data', 'value': m.unwrap}.jsify(),
      );
    } else {
      self.postMessage(<String, Object?>{'type': 'data', 'value': m}.jsify());
    }
  }

  /// Send error to the main app
  @override
  void sendResultError(IsolateException exception) {
    self.postMessage(exception.toMap().jsify());
  }

  /// Mark the Worker as initialized
  @override
  void initialized() {
    self.postMessage(IsolateState.initialized.toMap().jsify());
  }

  /// Close this `IsolateManagerWorkerController`.
  @override
  Future<void> close() async {
    self.close();
  }

  @override
  Completer<void> get ensureInitialized => throw UnimplementedError();

  @override
  Stream<R> get onMessage => throw UnimplementedError();

  @override
  void sendIsolate(dynamic message) => throw UnimplementedError();

  @override
  void sendIsolateState(IsolateState state) => throw UnimplementedError();
}
// coverage:ignore-end

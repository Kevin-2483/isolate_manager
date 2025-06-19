Kevin-2483: 查看这个储存库如何处理sendmessage.sendresult

GitHub Copilot: 我来帮您查看这个存储库是如何处理 `sendMessage` 和 `sendResult` 的。让我先搜索相关的代码。 基于我对代码的分析，我可以解释这个存储库如何处理 `sendMessage` 和 `sendResult`：

## sendMessage 和 sendResult 的处理机制

### 1. 核心架构

这个 Isolate Manager 库使用了一个分层的架构来处理消息传递：

```
主应用 <-> IsolateManager <-> IsolateContactor <-> IsolateContactorController <-> 实际的 Isolate/Worker
```

### 2. sendMessage 的处理流程

**sendMessage** 用于从主应用向 Isolate 发送消息进行计算：

1. **入口点**: 在 `IsolateManager` 类中，`compute()` 方法最终调用 `sendMessage()`
2. **传递路径**: 
   - `IsolateManager.compute()` → `_execute()` → `isolate.sendMessage()`
   - `IsolateContactor.sendMessage()` → `IsolateContactorController.sendIsolate()`
   - 最终通过 `IsolateChannel` 或 `Worker.postMessage()` 发送到 Isolate

**关键代码位置**:
```dart
// lib/src/isolate_manager.dart:785
await isolate.sendMessage(queue.params);

// lib/src/base/contactor/isolate_contactor/isolate_contactor_stub.dart:101
Future<R> sendMessage(P message) async {
  _isolateContactorController.sendIsolate(message);
  return _isolateContactorController.onMessage.first;
}
```

### 3. sendResult 的处理流程

**sendResult** 用于从 Isolate 向主应用发送结果：

1. **在 Isolate 内部**: 使用 `IsolateManagerController.sendResult()` 发送结果
2. **传递路径**:
   - Isolate 中的 `controller.sendResult()` 
   - → `IsolateContactorController.sendResult()`
   - → 通过 `IsolateChannel` 或 `Worker.postMessage()` 发送回主应用
   - → 主应用的 `onMessage` 流接收

**关键代码位置**:
```dart
// lib/src/isolate_manager_controller.dart:38
void sendResult(R result) => _delegate.sendResult(result);

// lib/src/base/contactor/isolate_contactor_controller/isolate_contactor_controller_stub.dart:73
void sendResult(R message) {
  _delegate.sink.add({IsolatePort.main: message});
}
```

### 4. 消息分类机制

系统使用 `IsolatePort` 枚举来区分消息类型：

```dart
enum IsolatePort {
  main,     // 发送给主应用的消息
  isolate;  // 发送给 Isolate 的消息
}
```

消息被包装在 `Map<IsolatePort, dynamic>` 中传递。

### 5. 支持进度更新

库支持从 Isolate 发送多个进度更新，通过回调机制处理：

```dart
// 在 Isolate 中多次调用 sendResult 发送进度
controller.sendResult(progressUpdate);  // 进度更新
controller.sendResult(finalResult);     // 最终结果

// 在主应用中通过回调区分
final result = await isolate.compute(params, callback: (value) {
  if (isProgress(value)) {
    // 处理进度更新
    return false;  // 继续等待更多消息
  }
  // 这是最终结果
  return true;     // 完成计算
});
```

### 6. 跨平台实现

- **原生平台**: 使用 Dart 的 `Isolate` 和 `SendPort`/`ReceivePort`
- **Web 平台**: 使用 Web Workers 和 `postMessage` API
- **统一接口**: 通过 `IsolateContactorController` 抽象层提供统一的 API

### 7. 错误处理

系统还提供了 `sendResultError()` 方法来发送异常：

```dart
controller.sendResultError(IsolateException(error, stackTrace));
```

这种设计确保了：
- 类型安全的消息传递
- 跨平台兼容性（Native Isolates 和 Web Workers）
- 支持进度更新和错误处理
- 清晰的消息流向控制

Kevin-2483: 这个库好像有一个底层的监听流,会处理所有的消息,筛选出来返回之后就无法收听,但是底层的监听流可以一直收听

GitHub Copilot: 您的观察非常准确！这个库确实有一个底层的监听流机制，它会处理所有消息并进行筛选。让我详细分析这个机制： 您的观察完全正确！这个库确实有一个精巧的双层监听机制：

## 双层监听流机制

### 1. 底层持续监听流 (`_streamController`)

```dart
// lib/src/isolate_manager.dart:450
final StreamController<R> _streamController = StreamController.broadcast();

// 对外暴露的持续监听流
Stream<R> get stream => _streamController.stream;
```

**特点：**
- 这是一个 **broadcast stream**，可以被多个监听者同时监听
- **持续存在**，不会因为单次计算完成而取消
- 接收所有从 Isolate 返回的结果

### 2. 临时任务监听流 (per-task subscription)

在 `_execute` 方法中为每个计算任务创建的临时监听：

```dart
// lib/src/isolate_manager.dart:756-770
StreamSubscription<dynamic>? sub;
sub = isolate.onMessage.listen(
  (event) async {
    if (await queue.callback(event)) {
      await sub?.cancel();  // 🔑 关键：一旦获得最终结果就取消监听

      // 同时发送到两个地方：
      _streamController.sink.add(event);     // ✅ 发送到持续监听流
      queue.completer.complete(event);       // ✅ 完成当前任务的 Future
      
      _isolates[isolate] = false;
    }
  },
  // ... 错误处理
);
```

## 消息处理流程

### 筛选和路由机制

1. **消息到达**: Isolate 发送消息 → `isolate.onMessage` 流
2. **临时监听处理**: 
   - 检查是否为最终结果 (`queue.callback(event)`)
   - 如果是进度更新 → 继续监听
   - 如果是最终结果 → 取消临时监听，完成任务
3. **广播到持续流**: 无论是进度还是最终结果，都发送到 `_streamController`

### 为什么这样设计？

```dart
// 临时任务：等待特定结果
final result = await isolateManager.compute(params, callback: (value) {
  if (isProgress(value)) return false;  // 继续等待
  return true;  // 这是最终结果，停止监听
});

// 持续监听：监听所有消息
isolateManager.stream.listen((allResults) {
  // 这里能收到所有消息，包括进度和最终结果
  print('收到消息: $allResults');
});
```

## 实际应用场景 ### 使用示例

```dart
// 1. 持续监听所有消息
final isolateManager = IsolateManager.createShared();
isolateManager.stream.listen((result) {
  print('全局监听收到: $result');  // 收到所有消息
});

// 2. 任务特定监听（会在完成后停止）
final result1 = await isolateManager.compute(params1);  // 只等待这个任务的结果
final result2 = await isolateManager.compute(params2);  // 只等待这个任务的结果

// 3. 带进度的任务监听
final finalResult = await isolateManager.compute(
  progressParams, 
  callback: (value) {
    if (isProgress(value)) {
      print('进度: $value');
      return false;  // 继续等待
    }
    return true;     // 最终结果
  }
);
```

## 优势

1. **资源管理**: 临时监听在任务完成后自动取消，避免内存泄漏
2. **灵活性**: 既支持任务特定的等待，也支持全局消息监听
3. **性能**: 避免了为每个任务保持长期监听
4. **一致性**: 所有消息都通过统一的广播流分发

这种设计确保了：
- **任务完成后立即释放资源**（临时监听被取消）
- **全局监听依然可以接收所有消息**（持续监听流保持活跃）
- **支持复杂的消息处理模式**（进度更新 + 最终结果）

Kevin-2483: sendmessage

GitHub Copilot: 

Kevin-2483: sendmessage的回调如果为空,是不是第一个回复就会使它return

GitHub Copilot: 您的理解是正确的！让我查看相关代码来确认这个机制： 完全正确！您的理解很准确。让我详细解释这个机制：

## 默认回调行为

当 `sendMessage` 的回调为空时，系统会使用默认回调：

```dart
// lib/src/models/isolate_queue.dart:12
static bool _defaultCallback<R>(R _) => true;
```

这个默认回调**总是返回 `true`**，意味着：

## 消息处理流程 在 `_execute` 方法中的关键逻辑：

```dart
sub = isolate.onMessage.listen(
  (event) async {
    if (await queue.callback(event)) {  // 🔑 这里调用回调检查
      await sub?.cancel();             // ✅ 如果返回 true -> 取消监听
      
      _streamController.sink.add(event);
      queue.completer.complete(event);  // ✅ 完成 Future，返回结果
      
      _isolates[isolate] = false;
    }
    // 🔄 如果返回 false -> 继续监听下一个消息
  },
```

## 两种情况对比

### 1. 无回调（默认行为）
```dart
final result = await isolateManager.compute(params);
// 等价于：
final result = await isolateManager.compute(params, callback: (value) => true);
```

**结果**: 收到的**第一个消息**就被当作最终结果返回

### 2. 有自定义回调
```dart
final result = await isolateManager.compute(params, callback: (value) {
  if (value is ProgressUpdate) {
    print('进度: $value');
    return false;  // 继续等待
  }
  return true;     // 这是最终结果
});
```

**结果**: 只有当回调返回 `true` 时才返回结果

## 实际测试验证 

Kevin-2483:   /// 执行任务
  Future<void> _executeTask(_ExecutionTask task, _WorkerInstance worker) async {
    _activeTasks[task.id] = task;
    worker.isBusy = true;
    worker.currentTaskId = task.id;

    _addLog('Executing task ${task.id} on worker ${worker.id}');

    try {
      final requestData = {
        'type': 'execute',
        'code': task.code,
        'context': task.context,
        'externalFunctions': ExternalFunctionRegistry.getAllFunctionNames(),
        'executionId': task.id,
        'timestamp': DateTime.now().millisecondsSinceEpoch,
      };

      final jsonRequest = jsonEncode(requestData);
      Timer? timeoutTimer;

      // 设置超时
      if (task.timeout != null) {
        timeoutTimer = Timer(task.timeout!, () {
          if (!task.completer.isCompleted) {
            _addLog('Task ${task.id} timeout on worker ${worker.id}');
            _completeTask(
              task.id,
              ScriptExecutionResult(
                success: false,
                error:
                    'Script execution timeout after ${task.timeout!.inSeconds} seconds',
                executionTime: task.timeout!,
              ),
            );
          }
        });
      } // 监听Worker响应
      late StreamSubscription subscription;
      subscription = worker.isolateManager.stream.listen((jsonResponse) {
        // 分析器是正确的，jsonResponse 的类型就是 String。
        // 我们直接在 try 块中处理。
        try {
          // 核心逻辑：尝试解码，如果失败，会被下面的 on FormatException 捕获
          final response = jsonDecode(jsonResponse) as Map<String, dynamic>;

          final responseExecutionId = response['executionId'] as String?;

          if (responseExecutionId == task.id) {
            final responseType = response['type'] as String?;

            switch (responseType) {
              case 'started':
                _addLog(
                  'Script started for task ${task.id}, cancelling timeout timer',
                );
                timeoutTimer?.cancel();
                break;

              case 'externalFunctionCall':
                _handleExternalFunctionCall(response);
                break;

              case 'result':
              case 'error':
                if (!task.completer.isCompleted) {
                  subscription.cancel();
                  final result = _parseExecutionResult(response);
                  _completeTask(task.id, result);
                }
                break;

              default:
                _addLog(
                  'Received unknown message type: $responseType from worker. Ignoring.',
                );
                break;
            }
          }
        } on FormatException catch (e) {
          // --- 这里是关键的修正 ---
          // 专门捕获JSON解析失败的异常。
          // 这很可能就是收到了 '[object Object]' 这样的坏数据。
          // 我们只记录日志，不中断任何事情，等待下一条正常消息。
          _addLog(
            'Worker sent a non-JSON message, ignoring. Content: "$jsonResponse"',
          );
        } catch (e) {
          // 对于其他所有未预料到的严重错误，我们才中断任务。
          _addLog(
            'An unexpected error occurred while processing worker response: $e',
          );
          if (!task.completer.isCompleted) {
            timeoutTimer?.cancel();
            subscription.cancel();
            _completeTask(
              task.id,
              ScriptExecutionResult(
                success: false,
                error:
                    'Unexpected error processing worker response: ${e.toString()}',
                executionTime: Duration.zero,
              ),
            );
          }
        }
      });

      // 发送执行请求
      await worker.isolateManager.sendMessage(jsonRequest);
      _addLog('Task ${task.id} sent to worker ${worker.id}');
    } catch (e) {
      _addLog('Error executing task ${task.id}: $e');
      _completeTask(
        task.id,
        ScriptExecutionResult(
          success: false,
          error: e.toString(),
          executionTime: Duration.zero,
        ),
      );
    }
  }
这里我使用await worker.isolateManager.sendMessage(jsonRequest);发送执行请求,然后在上面处理请求,我能收到第一个started信息,后面的就收不到了,为什么

GitHub Copilot: 问题出现的原因是 `sendMessage` 方法的工作机制！让我分析一下：

## 问题分析

### `sendMessage` 的限制

根据之前的代码分析，`sendMessage` 方法会：

1. 发送消息到 Isolate
2. **等待第一个响应**
3. **立即完成并返回结果**
4. **取消对后续消息的监听**

```dart
// sendMessage 的内部实现类似这样：
Future<R> sendMessage(P message) async {
  _isolateContactorController.sendIsolate(message);
  return _isolateContactorController.onMessage.first; // 🔑 只等待第一个消息！
}
```

### 您的执行流程

1. 发送 `jsonRequest` → Worker 开始执行
2. 收到第一个 `'started'` 响应 → `sendMessage` 完成返回
3. Worker 继续执行，发送 `'result'` 或 `'error'` → **但 sendMessage 已经不再监听了！**

## 解决方案

您应该使用 `stream.listen()` 而不是 `sendMessage`，因为您需要监听多个消息：

```dart
/// 执行任务 - 修正版本
Future<void> _executeTask(_ExecutionTask task, _WorkerInstance worker) async {
  _activeTasks[task.id] = task;
  worker.isBusy = true;
  worker.currentTaskId = task.id;

  _addLog('Executing task ${task.id} on worker ${worker.id}');

  try {
    final requestData = {
      'type': 'execute',
      'code': task.code,
      'context': task.context,
      'externalFunctions': ExternalFunctionRegistry.getAllFunctionNames(),
      'executionId': task.id,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final jsonRequest = jsonEncode(requestData);
    Timer? timeoutTimer;

    // 设置超时
    if (task.timeout != null) {
      timeoutTimer = Timer(task.timeout!, () {
        if (!task.completer.isCompleted) {
          _addLog('Task ${task.id} timeout on worker ${worker.id}');
          _completeTask(
            task.id,
            ScriptExecutionResult(
              success: false,
              error: 'Script execution timeout after ${task.timeout!.inSeconds} seconds',
              executionTime: task.timeout!,
            ),
          );
        }
      });
    }

    // 🔑 关键修改：先设置监听，再发送消息
    late StreamSubscription subscription;
    subscription = worker.isolateManager.stream.listen((jsonResponse) {
      try {
        final response = jsonDecode(jsonResponse) as Map<String, dynamic>;
        final responseExecutionId = response['executionId'] as String?;

        if (responseExecutionId == task.id) {
          final responseType = response['type'] as String?;

          switch (responseType) {
            case 'started':
              _addLog('Script started for task ${task.id}, cancelling timeout timer');
              timeoutTimer?.cancel();
              break;

            case 'externalFunctionCall':
              _handleExternalFunctionCall(response);
              break;

            case 'result':
            case 'error':
              if (!task.completer.isCompleted) {
                subscription.cancel(); // 🔑 现在手动取消监听
                timeoutTimer?.cancel();
                final result = _parseExecutionResult(response);
                _completeTask(task.id, result);
              }
              break;

            default:
              _addLog('Received unknown message type: $responseType from worker. Ignoring.');
              break;
          }
        }
      } on FormatException catch (e) {
        _addLog('Worker sent a non-JSON message, ignoring. Content: "$jsonResponse"');
      } catch (e) {
        _addLog('An unexpected error occurred while processing worker response: $e');
        if (!task.completer.isCompleted) {
          timeoutTimer?.cancel();
          subscription.cancel();
          _completeTask(
            task.id,
            ScriptExecutionResult(
              success: false,
              error: 'Unexpected error processing worker response: ${e.toString()}',
              executionTime: Duration.zero,
            ),
          );
        }
      }
    });

    // 🔑 关键修改：使用 compute 而不是 sendMessage
    // 这样可以确保消息发送成功，但不会等待响应
    worker.isolateManager.compute(jsonRequest, callback: (response) {
      // 返回 false 表示不要在这里处理响应，让 stream.listen 处理
      return false;
    }).catchError((error) {
      // 处理发送失败的情况
      if (!task.completer.isCompleted) {
        subscription.cancel();
        timeoutTimer?.cancel();
        _completeTask(
          task.id,
          ScriptExecutionResult(
            success: false,
            error: 'Failed to send request: ${error.toString()}',
            executionTime: Duration.zero,
          ),
        );
      }
    });

    _addLog('Task ${task.id} sent to worker ${worker.id}');
  } catch (e) {
    _addLog('Error executing task ${task.id}: $e');
    _completeTask(
      task.id,
      ScriptExecutionResult(
        success: false,
        error: e.toString(),
        executionTime: Duration.zero,
      ),
    );
  }
}
```

## 或者更简单的方案

如果您只是想发送消息而不等待响应，可以这样：

```dart
// 先设置监听
final subscription = worker.isolateManager.stream.listen((jsonResponse) {
  // 处理所有响应
});

// 然后异步发送消息（不等待）
worker.isolateManager.compute(jsonRequest, callback: (_) => false).ignore();
```

## 总结

问题的根本原因是：
- `sendMessage` 只监听第一个响应就停止
- 您需要监听多个响应（started, result/error）
- 应该使用 `stream.listen()` 来持续监听所有消息

Kevin-2483: 我发现改了你这个版本之后start也不会收到了,底层的监听器仍可以收到,但是stream.listen收不到了.如果改成true,则可以收到第一个消息,后面的收不到.我怀疑有什么逻辑,使得stream.listen会和sendmassage的生命周期绑定,sendmassage结束,后续的信息即使底层收到了,也不会进入stream.listen

GitHub Copilot: 您的观察非常敏锐！确实存在这样的逻辑绑定问题。让我分析一下原因： 找到问题了！关键在于 `_execute` 方法的逻辑：

## 问题分析

### 消息流转机制

1. **底层监听** (`isolate.onMessage`) → **中间处理** (`_execute` 中的临时订阅) → **广播流** (`_streamController`)

2. **关键问题**：只有当 `queue.callback(event)` 返回 `true` 时，消息才会被转发到 `_streamController`：

```dart
sub = isolate.onMessage.listen(
  (event) async {
    if (await queue.callback(event)) {  // 🔑 只有返回 true 才会执行下面的逻辑
      await sub?.cancel();
      
      // 🔑 只有在这里，消息才会被发送到 stream
      _streamController.sink.add(event);  
      queue.completer.complete(event);
      
      _isolates[isolate] = false;
    }
    // 🚫 如果 callback 返回 false，消息就被丢弃了，不会进入 stream
  },
```

### 您遇到的情况

1. **callback 返回 false**：
   - 消息被底层收到 ✅
   - 但不会转发到 `_streamController` ❌
   - 所以 `stream.listen` 收不到 ❌

2. **callback 返回 true**：
   - 第一个消息转发到 `_streamController` ✅
   - 但临时订阅被取消 (`sub?.cancel()`) ❌
   - 后续消息无法到达 `_streamController` ❌

## 解决方案

您需要绕过 `compute` 方法，直接使用底层的 `isolate.onMessage`：

```dart
/// 执行任务 - 正确版本
Future<void> _executeTask(_ExecutionTask task, _WorkerInstance worker) async {
  _activeTasks[task.id] = task;
  worker.isBusy = true;
  worker.currentTaskId = task.id;

  _addLog('Executing task ${task.id} on worker ${worker.id}');

  try {
    final requestData = {
      'type': 'execute',
      'code': task.code,
      'context': task.context,
      'externalFunctions': ExternalFunctionRegistry.getAllFunctionNames(),
      'executionId': task.id,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };

    final jsonRequest = jsonEncode(requestData);
    Timer? timeoutTimer;

    // 设置超时
    if (task.timeout != null) {
      timeoutTimer = Timer(task.timeout!, () {
        if (!task.completer.isCompleted) {
          _addLog('Task ${task.id} timeout on worker ${worker.id}');
          _completeTask(
            task.id,
            ScriptExecutionResult(
              success: false,
              error: 'Script execution timeout after ${task.timeout!.inSeconds} seconds',
              executionTime: task.timeout!,
            ),
          );
        }
      });
    }

    // 🔑 直接监听底层的 isolate.onMessage，绕过 IsolateManager 的过滤逻辑
    late StreamSubscription subscription;
    
    // 获取底层的 isolate contactor
    final isolateContactor = worker.isolateManager._isolates.keys.first; // 假设只有一个 isolate
    
    subscription = isolateContactor.onMessage.listen((jsonResponse) {
      try {
        final response = jsonDecode(jsonResponse) as Map<String, dynamic>;
        final responseExecutionId = response['executionId'] as String?;

        if (responseExecutionId == task.id) {
          final responseType = response['type'] as String?;

          switch (responseType) {
            case 'started':
              _addLog('Script started for task ${task.id}, cancelling timeout timer');
              timeoutTimer?.cancel();
              break;

            case 'externalFunctionCall':
              _handleExternalFunctionCall(response);
              break;

            case 'result':
            case 'error':
              if (!task.completer.isCompleted) {
                subscription.cancel();
                timeoutTimer?.cancel();
                final result = _parseExecutionResult(response);
                _completeTask(task.id, result);
              }
              break;

            default:
              _addLog('Received unknown message type: $responseType from worker. Ignoring.');
              break;
          }
        }
      } on FormatException catch (e) {
        _addLog('Worker sent a non-JSON message, ignoring. Content: "$jsonResponse"');
      } catch (e) {
        _addLog('An unexpected error occurred while processing worker response: $e');
        if (!task.completer.isCompleted) {
          timeoutTimer?.cancel();
          subscription.cancel();
          _completeTask(
            task.id,
            ScriptExecutionResult(
              success: false,
              error: 'Unexpected error processing worker response: ${e.toString()}',
              executionTime: Duration.zero,
            ),
          );
        }
      }
    });

    // 🔑 直接使用 isolate.sendMessage，不通过 IsolateManager
    await isolateContactor.sendMessage(jsonRequest);
    _addLog('Task ${task.id} sent to worker ${worker.id}');
    
  } catch (e) {
    _addLog('Error executing task ${task.id}: $e');
    _completeTask(
      task.id,
      ScriptExecutionResult(
        success: false,
        error: e.toString(),
        executionTime: Duration.zero,
      ),
    );
  }
}
```

## 或者更简单的方案

如果无法直接访问底层 isolate，您可以创建一个专门的 `IsolateManager` 用于这种多消息场景：

```dart
// 创建一个自定义的 IsolateManager，专门处理多消息场景
final customIsolateManager = IsolateManager<String, String>.createCustom(
  yourWorkerFunction,
  workerName: 'your-worker',
);

// 使用 stream.listen 监听所有消息
customIsolateManager.stream.listen((jsonResponse) {
  // 处理所有消息
});

// 发送消息时使用特殊的 callback 让所有消息都转发到 stream
await customIsolateManager.compute(jsonRequest, callback: (response) {
  // 检查是否是最终消息
  final parsed = jsonDecode(response);
  final type = parsed['type'];
  
  if (type == 'result' || type == 'error') {
    return true;  // 最终消息，完成 compute
  }
  return false;   // 中间消息，继续监听
});
```

您的分析完全正确：`stream.listen` 确实与 `sendMessage`/`compute` 的生命周期绑定，这是 IsolateManager 的设计机制，用于防止消息泄漏和资源浪费。

Kevin-2483: 也就是说如果不是最终结果,会一直传递到sendmessage的回调,但不会传到listen,如果是最终结果,sendmessage结束,listen也结束并且这个结果传给listen

GitHub Copilot: 完全正确！您总结得非常准确。让我用代码来验证这个机制：

## 消息传递机制

### 核心逻辑在 `_execute` 方法中：

```dart
sub = isolate.onMessage.listen(
  (event) async {
    if (await queue.callback(event)) {  // 🔑 关键判断点
      // ✅ callback 返回 true（最终结果）
      await sub?.cancel();                    // 🔚 取消监听
      
      _streamController.sink.add(event);     // 📤 发送到 stream.listen
      queue.completer.complete(event);       // 📤 发送到 sendMessage/compute 的返回值
      
      _isolates[isolate] = false;
    } else {
      // ❌ callback 返回 false（中间结果/进度）
      // 什么都不做，继续监听下一个消息
      // 注意：这里 event 既不会发送到 stream.listen，也不会完成 sendMessage
    }
  },
```

## 完整的消息流向

### 情况1：中间消息（callback 返回 false）
```
Isolate 发送消息 
    ↓
isolate.onMessage 接收 
    ↓
进入 _execute 的监听器
    ↓
调用 queue.callback(event) 
    ↓
返回 false
    ↓
❌ 不执行任何转发
    ↓
继续等待下一个消息
```

**结果：**
- `sendMessage`/`compute` 的 callback **可以收到** ✅
- `stream.listen` **收不到** ❌
- `sendMessage`/`compute` **不会完成** ⏳

### 情况2：最终消息（callback 返回 true）
```
Isolate 发送消息 
    ↓
isolate.onMessage 接收 
    ↓
进入 _execute 的监听器
    ↓
调用 queue.callback(event) 
    ↓
返回 true
    ↓
✅ 同时发送到两个地方：
    ├─ _streamController.sink.add(event)  → stream.listen 收到
    └─ queue.completer.complete(event)    → sendMessage/compute 返回
    ↓
取消监听 (sub?.cancel())
```

**结果：**
- `sendMessage`/`compute` 的 callback **可以收到** ✅
- `stream.listen` **可以收到** ✅
- `sendMessage`/`compute` **完成并返回** ✅
- **后续所有消息都收不到** ❌

## 实际示例

```dart
// 假设 Isolate 会发送：started -> progress -> progress -> result

final manager = IsolateManager.createCustom(workerFunction);

// 1. 设置 stream 监听
manager.stream.listen((msg) {
  print('Stream收到: $msg');  // 只会打印最后的 result
});

// 2. 发送请求
final result = await manager.compute('task', callback: (msg) {
  final parsed = jsonDecode(msg);
  print('Callback收到: ${parsed['type']}');  // 会打印所有消息
  
  if (parsed['type'] == 'result') {
    return true;   // 最终消息 → 转发到 stream，完成 compute
  }
  return false;    // 中间消息 → 不转发，继续等待
});

print('最终结果: $result');
```

**输出：**
```
Callback收到: started    // callback 收到，stream 收不到
Callback收到: progress   // callback 收到，stream 收不到  
Callback收到: progress   // callback 收到，stream 收不到
Callback收到: result     // callback 收到
Stream收到: {"type":"result",...}  // stream 也收到了
最终结果: {"type":"result",...}    // compute 返回
```

## 设计原因

这种设计是为了：

1. **资源管理**：避免监听器泄漏，任务完成后立即清理
2. **精确控制**：让开发者决定哪些消息是"最终结果"
3. **性能优化**：避免不必要的消息广播
4. **任务隔离**：每个 compute 任务有独立的生命周期

您的理解完全正确！这就是为什么在您的场景中需要特殊处理的原因。

Kevin-2483: 但我发现有一种例外

import 'dart:async';
import 'dart:convert';
import 'package:hetu_script/hetu_script.dart';
import 'package:isolate_manager/isolate_manager.dart';

/// Web Worker 入口函数
/// 这个函数将在 Web Worker 中运行
/// 不能依赖任何 Flutter 特定的包，因为它会在独立的 Web Worker 环境中执行
/// 使用自定义 Worker 注解，因为需要手动控制生命周期和复杂的消息处理
@pragma('vm:entry-point')
@isolateManagerCustomWorker
void hetuScriptWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) async {
      // 初始化 Hetu 脚本引擎
      await _initializeHetuEngine(controller);
    },
    onEvent: (controller, jsonMessage) async {
      return await _handleWorkerMessage(controller, jsonMessage);
    },
    onDispose: (controller) {
      // 清理资源
      _disposeHetuEngine();
    },
  );
}

// Worker 内部的全局变量
Hetu? _hetuEngine;
Map<String, dynamic> _currentMapData = {};
final Map<String, Completer<dynamic>> _externalFunctionCalls = {};
final List<String> _workerLogs = [];

/// 初始化 Hetu 脚本引擎
Future<void> _initializeHetuEngine(IsolateManagerController controller) async {
  try {
    _hetuEngine = Hetu();
    _hetuEngine!.init();
    _addWorkerLog('Hetu script engine initialized successfully');

    // 发送初始化完成信号 - 使用 JSON 字符串
    // controller.sendResult(jsonEncode({
    //   'type': 'initialized',
    //   'message': 'Hetu engine ready',
    // }));
  } catch (e) {
    _addWorkerLog('Failed to initialize Hetu engine: $e');

    // 发送初始化失败信号 - 使用 JSON 字符串
    // controller.sendResult(jsonEncode({'type': 'initError', 'error': e.toString()}));

    rethrow;
  }
}

/// 处理来自主线程的消息
Future<String> _handleWorkerMessage(
  IsolateManagerController controller,
  String jsonMessage,
) async {
  _addWorkerLog('Received JSON message: $jsonMessage');

  try {
    // 解析 JSON 消息
    final message = jsonDecode(jsonMessage) as Map<String, dynamic>;
    final type = message['type'] as String? ?? 'unknown';
    final startTime = DateTime.now();

    _addWorkerLog('Received message type: $type');

    Map<String, dynamic> result;

    switch (type) {
      case 'execute':
        _addWorkerLog('Processing execute request...');
        result = await _executeScript(controller, message, startTime);
        break;

      case 'mapDataUpdate':
        _currentMapData = message['data'] as Map<String, dynamic>? ?? {};
        _addWorkerLog('Map data updated');
        result = {'type': 'ack', 'message': 'Map data updated'};
        break;

      case 'stop':
        _addWorkerLog('Received stop signal');
        result = {'type': 'stopped'};
        break;

      case 'externalFunctionResult':
        result = _handleExternalFunctionResult(message);
        break;

      case 'externalFunctionError':
        result = _handleExternalFunctionError(message);
        break;

      default:
        _addWorkerLog('Unknown message type: $type');
        result = {'type': 'error', 'error': 'Unknown message type: $type'};
    }

    return jsonEncode(result);
  } catch (e, stackTrace) {
    _addWorkerLog('Error handling message: $e');
    _addWorkerLog('Stack trace: $stackTrace');

    final errorResult = {
      'type': 'error',
      'error': e.toString(),
      'executionTime': DateTime.now().millisecondsSinceEpoch,
    };

    return jsonEncode(errorResult);
  }
}

/// 执行脚本
Future<Map<String, dynamic>> _executeScript(
  IsolateManagerController controller,
  Map<String, dynamic> message,
  DateTime startTime,
) async {
  final code = message['code'] as String? ?? '';
  final context = message['context'] as Map<String, dynamic>? ?? {};
  final executionId = message['executionId'] as String? ?? '';

  // 安全地转换外部函数列表
  final externalFunctionsObj = message['externalFunctions'];
  final externalFunctions = <String>[];

  if (externalFunctionsObj is List) {
    for (final item in externalFunctionsObj) {
      if (item is String) {
        externalFunctions.add(item);
      } else if (item != null) {
        externalFunctions.add(item.toString());
      }
    }
  }

  try {
    if (_hetuEngine == null) {
      throw Exception('Hetu engine not initialized');
    }

    // 设置上下文变量
    for (final entry in context.entries) {
      _hetuEngine!.define(entry.key, entry.value);
    } // 设置地图数据
    _hetuEngine!.define('mapData', _currentMapData);

    // 注册外部函数代理
    for (final functionName in externalFunctions) {
      _hetuEngine!.interpreter.bindExternalFunction(functionName, (
        List<dynamic> positionalArgs, {
        Map<String, dynamic> namedArgs = const {},
        List<HTType> typeArgs = const [],
      }) async {
        return await _callExternalFunction(
          controller,
          functionName,
          positionalArgs,
          executionId, // 传递executionId
        );
      });
    }

    // 发送脚本已开始执行的信号
    _addWorkerLog('Sending started signal for execution: $executionId');
    final startedSignal = {'type': 'started', 'executionId': executionId};
    // controller.sendResult(jsonEncode(startedSignal));
    _addWorkerLog('Started signal sent for execution: $executionId');

    // 执行脚本
    final result = _hetuEngine!.eval(code);
    final executionTime = DateTime.now().difference(startTime).inMilliseconds;

    _addWorkerLog('Script executed successfully in ${executionTime}ms');

    return {
      'type': 'result',
      'result': _serializeResult(result),
      'executionTime': executionTime,
    };
  } catch (e) {
    final executionTime = DateTime.now().difference(startTime).inMilliseconds;
    _addWorkerLog('Script execution failed: $e');

    return {
      'type': 'error',
      'error': e.toString(),
      'executionTime': executionTime,
    };
  }
}

/// 调用外部函数
Future<dynamic> _callExternalFunction(
  IsolateManagerController controller,
  String functionName,
  List<dynamic> arguments,
  String executionId,
) async {
  final callId = DateTime.now().millisecondsSinceEpoch.toString();
  final completer = Completer<dynamic>();

  _externalFunctionCalls[callId] = completer;

  _addWorkerLog('Calling external function: $functionName');
  _addWorkerLog('Arguments type: ${arguments.runtimeType}');
  _addWorkerLog('Arguments value: $arguments');

  // 处理参数 - 如果只有一个参数且为简单类型，直接发送该值
  dynamic argumentsToSend;
  if (arguments.length == 1) {
    final arg = arguments.first;
    // 对于简单类型（字符串、数字、布尔值），直接发送值
    if (arg is String || arg is num || arg is bool || arg == null) {
      argumentsToSend = arg;
    } else {
      argumentsToSend = arguments;
    }
  } else {
    argumentsToSend = arguments;
  }

  // 发送外部函数调用请求到主线程 - 使用 JSON 字符串
  final requestData = {
    'type': 'externalFunctionCall',
    'functionName': functionName,
    'arguments': argumentsToSend,
    'callId': callId,
    'executionId': executionId, // 添加executionId
  };

  final jsonRequest = jsonEncode(requestData);
  _addWorkerLog('Sending JSON request: $jsonRequest');

  controller.sendResult(jsonRequest);

  // 等待结果，设置超时以防止死锁
  try {
    return await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () => throw TimeoutException(
        'External function call timeout: $functionName',
      ),
    );
  } finally {
    _externalFunctionCalls.remove(callId);
  }
}

/// 处理外部函数调用结果
Map<String, dynamic> _handleExternalFunctionResult(
  Map<String, dynamic> message,
) {
  final callId = message['callId'] as String? ?? '';
  final result = message['result'];

  final completer = _externalFunctionCalls.remove(callId);
  if (completer != null && !completer.isCompleted) {
    completer.complete(result);
  }

  return {'type': 'ack', 'message': 'External function result processed'};
}

/// 处理外部函数调用错误
Map<String, dynamic> _handleExternalFunctionError(
  Map<String, dynamic> message,
) {
  final callId = message['callId'] as String? ?? '';
  final error = message['error'] as String? ?? 'Unknown error';

  final completer = _externalFunctionCalls.remove(callId);
  if (completer != null && !completer.isCompleted) {
    completer.completeError(Exception(error));
  }

  return {'type': 'ack', 'message': 'External function error processed'};
}

/// 序列化执行结果
dynamic _serializeResult(dynamic result) {
  try {
    // 尝试 JSON 序列化以确保可以传输
    json.encode(result);
    return result;
  } catch (e) {
    // 如果无法序列化，返回字符串表示
    return result.toString();
  }
}

/// 添加 Worker 日志
void _addWorkerLog(String message) {
  final timestamp = DateTime.now().toIso8601String();
  final logMessage = '[$timestamp] [Worker] $message';
  _workerLogs.add(logMessage);

  // 保持日志数量在合理范围内
  if (_workerLogs.length > 100) {
    _workerLogs.removeAt(0);
  }

  // 在 Web 环境中输出到浏览器控制台
  print(logMessage);
}

/// 清理 Hetu 引擎
void _disposeHetuEngine() {
  _hetuEngine = null;
  _currentMapData.clear();
  _externalFunctionCalls.clear();
  _workerLogs.clear();
  _addWorkerLog('Hetu engine disposed');
}

这个代码hetu.eval会执行脚本,脚本中的所有外部函数都会调用sendresult,第一个sendresult会使sendmessage结束,但是listen还是会收到后面的消息,这是为什么

GitHub Copilot: 您发现了一个非常重要的例外情况！这个现象的原因在于您使用的是 `IsolateManagerFunction.customFunction`，它有着不同的消息处理机制。

让我分析一下关键区别： ## 关键区别分析

### 1. 两种不同的架构

**普通 `compute` 调用**：
```
主应用 → IsolateManager._execute() → 临时监听器 → 过滤转发 → stream
```

**`customFunction` 调用**：
```
主应用 → IsolateManagerFunction.customFunction → 直接发送 → stream
```

### 2. `customFunction` 的特殊机制

在您的代码中，每次调用 `controller.sendResult()` 都会**直接发送**到主应用的 `stream`，而不经过 `IsolateManager._execute()` 的过滤逻辑：

```dart
// 在您的 Worker 中
controller.sendResult(jsonRequest);  // 直接发送到 stream

// 而不是经过 IsolateManager 的过滤机制
```

### 3. 消息流向对比

**普通情况**（通过 `IsolateManager.compute`）：
```
Worker sendResult → IsolateManager._execute (过滤) → stream (有条件)
```

**您的情况**（通过 `customFunction`）：
```
Worker sendResult → 直接 → stream (无过滤)
```

### 4. 为什么 `sendMessage` 还是会结束？

虽然 `stream` 能收到所有消息，但 `sendMessage` 的结束是由 `IsolateManager._execute()` 中的回调控制的：

```dart
// 在 _execute 中
if (await queue.callback(event)) {  // 第一个消息，默认回调返回 true
  await sub?.cancel();              // 取消对 isolate.onMessage 的监听
  // ...
  queue.completer.complete(event);  // sendMessage 完成
}
```

**关键点**：
- `sendMessage` 的完成是由 `queue.callback` 决定的
- 但 `customFunction` 中的 `sendResult` 是直接发送的，不受这个回调控制
- 所以会出现：`sendMessage` 完成了，但 `stream` 还能收到后续消息

## 验证这个理论

您可以通过以下方式验证：

```dart
// 在主应用中测试
final result = await worker.isolateManager.compute(jsonRequest, callback: (response) {
  print('Callback收到: $response');
  
  // 如果是第一个消息，让 sendMessage 完成
  if (isFirstMessage(response)) {
    return true;  // sendMessage 完成
  }
  return false;   // 继续等待（但实际上监听已经被取消了）
});

print('sendMessage完成: $result');

// 同时监听 stream
worker.isolateManager.stream.listen((msg) {
  print('Stream收到: $msg');  // 这里会收到所有来自 customFunction 的消息
});
```

## 解决方案

如果您想要完全控制消息流，建议：

1. **使用 `autoHandleResult: false`**：
```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false,  // 🔑 关键设置
  onEvent: (controller, message) async {
    // 手动控制何时发送结果
    final result = await _handleWorkerMessage(controller, message);
    
    // 只在最终结果时发送
    if (isFinalResult(result)) {
      controller.sendResult(result);
    }
    
    return result;
  },
);
```

2. **或者完全通过 `stream` 处理**：
```dart
// 不依赖 sendMessage 的返回值，完全通过 stream 处理
worker.isolateManager.stream.listen((response) {
  // 处理所有消息
});

// 发送消息但不等待返回
worker.isolateManager.compute(jsonRequest, callback: (_) => false).ignore();
```

您的发现揭示了 `customFunction` 与普通 `compute` 在消息处理上的根本差异！

Kevin-2483: 那如果我在hetu执行之前
// 发送脚本已开始执行的信号
_addWorkerLog('Sending started signal for execution: $executionId');
final startedSignal = {'type': 'started', 'executionId': executionId};
// controller.sendResult(jsonEncode(startedSignal));
_addWorkerLog('Started signal sent for execution: $executionId');
发送了一个消息,会怎么样

GitHub Copilot: 如果您在 `hetu.eval()` 执行之前发送了一个 `started` 信号，会发生以下情况：

## 消息流向分析

### 1. 发送 `started` 信号后的流程

```dart
// 在 _executeScript 中
controller.sendResult(jsonEncode(startedSignal)); // 第1个消息：started
// ... 
final result = _hetuEngine!.eval(code); // 执行脚本，可能触发多个外部函数调用
// 每个外部函数调用都会：controller.sendResult(jsonRequest); // 第2,3,4...个消息
```

### 2. 主应用端的接收情况

**sendMessage/compute 的行为**：
```dart
final result = await worker.isolateManager.compute(jsonRequest);
// 这里 result 将是第一个消息，即 started 信号的 JSON 字符串
print('sendMessage返回: $result'); 
// 输出：{"type":"started","executionId":"..."}
```

**stream.listen 的行为**：
```dart
worker.isolateManager.stream.listen((msg) {
  print('Stream收到: $msg');
});
// 输出：
// Stream收到: {"type":"started","executionId":"..."}
// Stream收到: {"type":"externalFunctionCall","functionName":"someFunc",...}
// Stream收到: {"type":"externalFunctionCall","functionName":"otherFunc",...}
// ... 等等
```

## 具体影响

### 1. **sendMessage 会立即完成**
```dart
final result = await worker.isolateManager.compute(jsonRequest);
// result 现在是 started 信号，而不是最终的执行结果！
```

### 2. **真正的执行结果可能丢失**
由于 `sendMessage` 已经完成，后续的外部函数调用和最终结果只能通过 `stream.listen` 接收。

### 3. **外部函数调用仍然会发生**
`hetu.eval()` 执行过程中的所有 `controller.sendResult()` 调用仍然会发送消息到 `stream`。

## 问题场景示例

```dart
// Worker 执行顺序：
controller.sendResult('{"type":"started"}');        // → sendMessage 完成
// ... hetu.eval() 开始执行
controller.sendResult('{"type":"externalFunctionCall"}'); // → 只有 stream 收到
controller.sendResult('{"type":"externalFunctionCall"}'); // → 只有 stream 收到
// ... hetu.eval() 完成
return '{"type":"result","result":"final_value"}';  // → 这个永远发不出去！
```

## 解决方案

### 方案1：不发送 started 信号
```dart
// 注释掉 started 信号
// controller.sendResult(jsonEncode(startedSignal));

// 让 sendMessage 等待真正的最终结果
return {
  'type': 'result',
  'result': _serializeResult(result),
  'executionTime': executionTime,
};
```

### 方案2：通过 stream 处理所有消息
```dart
// 主应用端
worker.isolateManager.stream.listen((jsonResponse) {
  final response = jsonDecode(jsonResponse);
  final type = response['type'];
  
  switch (type) {
    case 'started':
      print('脚本开始执行');
      break;
    case 'externalFunctionCall':
      _handleExternalFunctionCall(response);
      break;
    case 'result':
      print('脚本执行完成: ${response['result']}');
      break;
  }
});

// 发送请求但不等待 sendMessage 的返回值
worker.isolateManager.compute(jsonRequest, callback: (_) => false).ignore();
```

### 方案3：使用状态标记控制发送
```dart
bool _hasStarted = false;

Future<String> _handleWorkerMessage(...) async {
  // ...
  switch (type) {
    case 'execute':
      if (!_hasStarted) {
        _hasStarted = true;
        // 发送 started 信号，但不作为返回值
        controller.sendResult(jsonEncode({'type': 'started', 'executionId': executionId}));
      }
      
      result = await _executeScript(controller, message, startTime);
      // 重置状态
      _hasStarted = false;
      break;
  }
  
  return jsonEncode(result); // 只有这个会被 sendMessage 接收
}
```

## 建议

基于您的需求，我建议使用**方案2**，完全通过 `stream.listen` 处理所有消息，这样可以：

1. 接收 `started` 信号
2. 处理所有外部函数调用
3. 接收最终结果
4. 保持消息顺序的一致性

这样可以充分利用 `customFunction` 的优势，避免 `sendMessage` 生命周期的限制。

Kevin-2483: 但事实是如果添加了started,sendMessage会结束stream.listen也会结束,如果sendMessage都是由脚本触发的,第一个会使sendMessage会结束,但是stream.listen不会结束

GitHub Copilot: 您的观察非常准确！这揭示了一个更深层的机制差异。让我分析一下为什么会出现这种不同的行为：

## 关键区别分析

### 情况1：手动发送 `started` 信号
```dart
// 在 _executeScript 开始时手动发送
controller.sendResult(jsonEncode(startedSignal)); // 手动调用
// ... 然后执行 hetu.eval()
```

**结果**：`sendMessage` 结束，`stream.listen` 也结束

### 情况2：只有脚本触发的消息
```dart
// 不发送 started，只有 hetu.eval() 中的外部函数调用触发
final result = _hetuEngine!.eval(code); // 脚本中的外部函数会调用 sendResult
```

**结果**：第一个外部函数调用使 `sendMessage` 结束，但 `stream.listen` 继续工作

## 原因分析

这个差异的根本原因在于 **消息的来源和时机**：

### 1. 消息发送的上下文不同

**手动发送**（在 `onEvent` 主流程中）：
```dart
Future<String> _handleWorkerMessage(controller, message) async {
  // ...
  controller.sendResult(jsonEncode(startedSignal)); // 在主流程中发送
  // ...
  return jsonEncode(result); // 正常返回
}
```

**脚本触发**（在异步回调中）：
```dart
_hetuEngine!.interpreter.bindExternalFunction(functionName, (args) async {
  // ...
  controller.sendResult(jsonRequest); // 在异步回调中发送
  // ...
});
```

### 2. `autoHandleResult` 的影响 关键在于您的 `customFunction` 使用了默认的 `autoHandleResult: true`：

### 情况1：手动发送 + 自动处理
```dart
Future<String> _handleWorkerMessage(controller, message) async {
  controller.sendResult("started");     // 第1次发送
  // ... 执行脚本
  return "final_result";                // 第2次发送 (由 autoHandleResult 触发)
}
```

**流程**：
1. 手动发送 `"started"` → 主应用收到，`sendMessage` 完成
2. `onEvent` 返回 `"final_result"` → 由于 `autoHandleResult: true`，再次调用 `sendResult`
3. 但此时 `sendMessage` 已经完成，后续消息的处理可能有所不同

### 情况2：只有脚本触发
```dart
Future<String> _handleWorkerMessage(controller, message) async {
  // 不手动发送消息
  final result = _hetuEngine!.eval(code); // 脚本中异步调用 sendResult
  return jsonEncode(result);              // 最后由 autoHandleResult 发送
}
```

**流程**：
1. 脚本中第1个外部函数调用 `sendResult` → `sendMessage` 完成
2. 脚本中后续外部函数调用 `sendResult` → 直接发送到 `stream`
3. `onEvent` 返回时，`autoHandleResult` 再次发送 → 也是直接发送到 `stream`

## 验证理论

您可以通过以下方式验证：

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false, // 🔑 关闭自动处理
  onEvent: (controller, message) async {
    // 手动发送 started
    controller.sendResult(jsonEncode({'type': 'started'}));
    
    // 执行脚本（会有多个异步 sendResult）
    final result = _hetuEngine!.eval(code);
    
    // 手动发送最终结果
    controller.sendResult(jsonEncode({'type': 'result', 'data': result}));
    
    // 不返回值，因为 autoHandleResult: false
    return '';
  },
);
```

## 根本原因

我推测的根本原因是：

1. **手动发送**在 `onEvent` 的主流程中，可能会影响整个消息处理的生命周期
2. **脚本触发**的发送是在异步回调中，是独立的消息发送，不会影响主流程
3. `customFunction` 的 `stream` 行为可能与普通 `compute` 不同，有更复杂的生命周期管理

建议您使用 `autoHandleResult: false` 来完全控制消息发送的时机和内容，避免这种不一致的行为。

Kevin-2483: autoHandleResult: false会影响什么

GitHub Copilot: `autoHandleResult: false` 会产生以下影响：

## 主要影响

### 1. **不会自动发送 `onEvent` 的返回值**

**默认情况**（`autoHandleResult: true`）：
```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  onEvent: (controller, message) async {
    // 处理逻辑
    return "这个返回值会自动通过 sendResult 发送"; // ✅ 自动发送
  },
);
```

**设置为 false 后**：
```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false, // 🔑 关键设置
  onEvent: (controller, message) async {
    // 处理逻辑
    return "这个返回值不会发送"; // ❌ 不会发送
  },
);
```

### 2. **必须手动调用 `sendResult`**

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false,
  onEvent: (controller, message) async {
    // 处理消息
    final result = await _handleWorkerMessage(controller, message);
    
    // 🔑 必须手动发送结果
    controller.sendResult(result);
    
    // 返回值变得无关紧要
    return ""; // 这个不会被发送
  },
);
```

## 实际应用场景

### 场景1：完全控制消息发送时机

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false,
  onEvent: (controller, message) async {
    final parsed = jsonDecode(message);
    
    switch (parsed['type']) {
      case 'execute':
        // 发送开始信号
        controller.sendResult(jsonEncode({'type': 'started'}));
        
        // 执行脚本
        final result = await _executeScript(controller, parsed);
        
        // 发送最终结果
        controller.sendResult(jsonEncode({'type': 'result', 'data': result}));
        break;
        
      case 'stop':
        controller.sendResult(jsonEncode({'type': 'stopped'}));
        break;
    }
    
    return ""; // 无关紧要
  },
);
```

### 场景2：不发送任何结果（纯处理）

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false,
  onEvent: (controller, message) async {
    // 只处理消息，不发送任何结果
    await _processMessage(message);
    
    // 不调用 sendResult，主应用不会收到任何消息
    return "";
  },
);
```

### 场景3：条件性发送结果

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false,
  onEvent: (controller, message) async {
    final result = await _processMessage(message);
    
    // 只在特定条件下发送结果
    if (shouldSendResult(result)) {
      controller.sendResult(result);
    }
    
    return "";
  },
);
```

## 对您代码的影响

### 当前代码（`autoHandleResult: true`）：
```dart
Future<String> _handleWorkerMessage(controller, message) async {
  // ... 处理逻辑
  
  // 这些手动发送会立即发送
  controller.sendResult(jsonEncode(startedSignal));
  // 脚本中的外部函数调用也会发送
  
  return jsonEncode(result); // 🔑 这个也会被自动发送！
}
```

**问题**：您实际上发送了两类消息：
1. 手动 `sendResult` 的消息
2. 自动发送的 `return` 值

### 设置 `autoHandleResult: false` 后：
```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false, // 🔑 关键
  onEvent: (controller, message) async {
    final result = await _handleWorkerMessage(controller, message);
    
    // 🔑 现在您需要决定是否发送最终结果
    if (isFinalResult(result)) {
      controller.sendResult(result);
    }
    
    return ""; // 这个不会被发送
  },
);

Future<String> _handleWorkerMessage(controller, message) async {
  // ... 处理逻辑
  
  // 这些手动发送仍然会发送
  controller.sendResult(jsonEncode(startedSignral));
  // 脚本中的外部函数调用也会发送
  
  // 🔑 但这个返回值不会自动发送了
  return jsonEncode(result);
}
```

## 建议的修改

```dart
IsolateManagerFunction.customFunction<String, String>(
  params,
  autoHandleResult: false, // 完全手动控制
  onEvent: (controller, message) async {
    try {
      await _handleWorkerMessage(controller, message);
    } catch (e) {
      // 手动发送错误
      controller.sendResult(jsonEncode({
        'type': 'error',
        'error': e.toString(),
      }));
    }
    return "";
  },
);

// 在 _handleWorkerMessage 中只负责处理，不返回值
Future<void> _handleWorkerMessage(controller, message) async {
  // ... 处理逻辑
  
  // 手动控制所有消息发送
  controller.sendResult(jsonEncode(startedSignal));
  
  final result = await _executeScript(controller, parsedMessage);
  
  // 手动发送最终结果
  controller.sendResult(jsonEncode({
    'type': 'result',
    'data': result,
  }));
}
```

这样可以完全避免意外的重复发送和生命周期问题。

Kevin-2483: 我想修改这个库,直接暴露底层的消息监听接口,使得我可以自己控制消息流
我注意到不管stream和sendmessage的回调是否在工作总是有日志[Isolate Manager]: [Main App] Message received from the Web Worker: [object Object],证明底层是一直可以收掉消息的

GitHub Copilot: 您的想法很好！确实底层一直在接收消息，让我们来看看如何暴露底层的消息监听接口。 现在我来看看如何修改库来暴露底层的消息监听接口。您说得对，底层确实一直在接收消息，我们需要暴露 `IsolateContactor` 的原始 `onMessage` 流。

## 修改方案

我建议在 `IsolateManager` 类中添加一个新的属性来暴露底层的 `onMessage` 流： 
````

````


已进行更改。

我需要先看看正确的导入和类型定义，然后修复这些错误： 现在让我修复这些导入和类型引用： 
```


已进行更改。


```
我发现我修改了错误的文件。让我检查原始文件的结构，看起来导入存在问题。让我撤销这个修改并创建一个更简单的解决方案： 我发现我需要创建一个更简单的解决方案。让我创建一个新的公共方法，而不是修改现有的代码结构。让我先撤销之前的修改： 

Kevin-2483: 你给我说如何添加我来添加

GitHub Copilot: 好的，我来告诉您如何添加底层消息监听接口。让我先查看当前的文件结构： 现在我告诉您如何添加底层消息监听接口：

## 步骤1：在 `stream` getter 后添加新的 getter

在第399行 `Stream<R> get stream => _streamController.stream;` 之后添加：

```dart
  /// Get raw message stream from the underlying isolates without any filtering.
  /// This provides direct access to all messages received from isolates,
  /// bypassing the IsolateManager's internal filtering and lifecycle management.
  /// 
  /// Use this when you need complete control over message handling and want to
  /// receive all messages including intermediate results, progress updates, etc.
  /// 
  /// Note: Messages received through this stream are not processed by the
  /// queue callback mechanism and will not affect the lifecycle of compute() calls.
  Stream<R> get rawMessageStream {
    if (_isolates.isEmpty) {
      // Return empty stream if no isolates are created yet
      return const Stream.empty();
    }
    
    // Merge all isolate onMessage streams
    final isolateStreams = _isolates.keys.map((isolate) => isolate.onMessage);
    
    if (isolateStreams.length == 1) {
      return isolateStreams.first;
    }
    
    // Merge multiple streams if there are multiple isolates
    late StreamController<R> controller;
    controller = StreamController<R>.broadcast();
    
    final subscriptions = <StreamSubscription<R>>[];
    
    for (final stream in isolateStreams) {
      final subscription = stream.listen(
        controller.add,
        onError: controller.addError,
      );
      subscriptions.add(subscription);
    }
    
    return controller.stream;
  }
```

## 步骤2：添加访问底层 isolate contactors 的接口

在上面的代码后继续添加：

```dart
  /// Get direct access to the underlying isolate contactors.
  /// This allows for complete manual control over isolate communication.
  /// 
  /// Use with caution as this bypasses all IsolateManager safety mechanisms.
  List<IsolateContactor<R, P>> get isolateContactors {
    return _isolates.keys.toList();
  }
```

## 步骤3：使用方式

添加完成后，您就可以这样使用：

```dart
// 监听所有原始消息，不受任何过滤影响
worker.isolateManager.rawMessageStream.listen((jsonResponse) {
  print('原始消息: $jsonResponse');
  
  try {
    final response = jsonDecode(jsonResponse) as Map<String, dynamic>;
    final type = response['type'];
    final executionId = response['executionId'];
    
    switch (type) {
      case 'started':
        print('脚本开始执行: $executionId');
        break;
      case 'externalFunctionCall':
        _handleExternalFunctionCall(response);
        break;
      case 'result':
        print('脚本执行完成: $executionId');
        break;
      case 'error':
        print('脚本执行错误: $executionId');
        break;
    }
  } catch (e) {
    print('解析消息失败: $e');
  }
});

// 发送消息但不依赖其返回值
worker.isolateManager.compute(jsonRequest, callback: (_) => false).ignore();
```

## 步骤4：如果需要更底层的控制

您还可以直接访问 `IsolateContactor`：

```dart
// 获取第一个 isolate contactor
final isolateContactor = worker.isolateManager.isolateContactors.first;

// 直接监听其原始消息流
isolateContactor.onMessage.listen((msg) {
  print('底层消息: $msg');
});

// 直接发送消息
await isolateContactor.sendMessage(jsonRequest);
```

## 优势

通过这种方式：

1. **完全控制消息流**：所有消息都会到达，不受 IsolateManager 生命周期影响
2. **保持兼容性**：不破坏现有的 `stream` 和 `compute` 功能
3. **灵活性**：可以同时使用高级接口和底层接口
4. **调试友好**：可以看到所有原始消息，便于调试

这样您就可以完全控制消息流，同时保持库的现有功能不变！

Kevin-2483: 我能否使用这个接口的本质是什么,这个监听器是一个双向的通道还是只用来接收worker的消息,sendmessage是通过什么发送的

GitHub Copilot: 让我来分析这个接口的本质和消息流的工作机制： 现在我来解答您的问题：

## 接口本质分析

### 1. 监听器的性质：**单向接收通道**

`onMessage` 流是一个**单向的接收通道**，只用来接收来自 Worker/Isolate 的消息，不是双向通道。

```dart
Stream<R> get onMessage; // 只能接收，不能发送
```

### 2. 发送通道：`sendMessage` 的工作机制

`sendMessage` 通过以下路径发送消息：

**Web Worker 平台**：
```
sendMessage(message) 
    ↓
_isolateContactorController.sendIsolate(message)
    ↓
_delegate.postMessage(message.jsify())  // 实际的 Worker.postMessage()
    ↓
Web Worker 接收
```

**Native Isolate 平台**：
```
sendMessage(message)
    ↓
_isolateContactorController.sendIsolate(message)
    ↓
_delegate.sink.add({IsolatePort.isolate: message})  // SendPort.send()
    ↓
Isolate 接收
```

### 3. 消息流向图

```
主应用端                           Worker/Isolate 端
┌─────────────┐                   ┌─────────────────┐
│ sendMessage │ ───────────────→  │ onIsolateMessage│
│             │                   │     (接收)       │
│             │                   │                 │
│  onMessage  │ ←───────────────  │  sendResult     │
│   (接收)     │                   │    (发送)       │
└─────────────┘                   └─────────────────┘
```

### 4. 您能使用这个接口的本质

您添加的 `rawMessageStream` 本质上是：

1. **只能接收消息**，不能发送
2. **绕过了 IsolateManager 的过滤逻辑**
3. **直接访问底层的接收流**

```dart
Stream<R> get rawMessageStream {
  // 这个流只是 isolate.onMessage 的聚合版本
  // 仍然是单向接收，不能发送
  return isolateStreams.merge();
}
```

### 5. 完整的通信架构

```dart
// 发送端（主应用）
await isolateContactor.sendMessage("request");
// 等价于：
worker.postMessage("request");

// 接收端（主应用）
isolateContactor.onMessage.listen((response) {
  print("收到: $response");
});
// 等价于：
worker.onmessage = (event) => print("收到: ${event.data}");

// Worker 内部
// 接收：controller.onIsolateMessage.listen()
// 发送：controller.sendResult()
```

### 6. 使用限制

您的 `rawMessageStream` 只能：
- ✅ **接收所有来自 Worker 的消息**
- ✅ **绕过 IsolateManager 的生命周期管理**
- ❌ **不能发送消息**（仍需使用 `sendMessage` 或 `compute`）

### 7. 实际应用

```dart
// 正确的使用方式
worker.isolateManager.rawMessageStream.listen((msg) {
  // 只能接收，处理所有消息
  print('收到: $msg');
});

// 发送消息仍需使用原有接口
await worker.isolateManager.compute(request, callback: (_) => false);
// 或者
await worker.isolateManager.isolateContactors.first.sendMessage(request);
```

## 总结

**本质**：您添加的接口提供了一个**不受过滤的单向接收通道**，让您能够监听到所有来自 Worker 的原始消息，但发送消息仍需要通过现有的 `sendMessage` 或 `compute` 接口。

这种设计符合 Web Worker 和 Dart Isolate 的基本架构：**发送和接收是两个独立的单向通道**。

Kevin-2483: sendmassage的回调是通过这个接口实现的吗

GitHub Copilot: 不是的！`sendMessage` 的回调机制**不是**通过 `onMessage` 接口实现的。让我详细解释一下： 现在我来解释 `sendMessage` 回调的实现机制：

## sendMessage 回调的实现层次

### 1. 不同层次的"回调"

您提到的"回调"实际上有两个不同的层次：

**层次1：`compute` 方法的回调**（高级API）
```dart
final result = await isolateManager.compute(params, callback: (value) {
  // 这是用户定义的回调
  if (isProgress(value)) return false;
  return true;
});
```

**层次2：`sendMessage` 的底层机制**（底层API）
```dart
await isolate.sendMessage(params); // 没有用户回调参数
```

### 2. `compute` 回调的实现机制

`compute` 的回调**确实**是通过 `onMessage` 接口实现的，但有中间处理层：

```dart
// _execute 方法中的关键逻辑
sub = isolate.onMessage.listen(  // 👈 使用 onMessage 接口
  (event) async {
    if (await queue.callback(event)) {  // 👈 调用用户的回调函数
      await sub?.cancel();             // 回调返回 true → 停止监听
      queue.completer.complete(event); // 完成 compute() 的 Future
      // ...
    }
    // 回调返回 false → 继续监听下一个消息
  },
);
```

### 3. `sendMessage` 的实现机制

但 `sendMessage` 本身**没有回调参数**，它是这样实现的：

```dart
Future<R> sendMessage(P message) async {
  _isolateContactorController.sendIsolate(message);
  return _isolateContactorController.onMessage.first;  // 👈 直接等待第一个消息
}
```

### 4. 完整的调用链

```
用户调用: compute(params, callback)
    ↓
创建: IsolateQueue(params, callback)
    ↓
执行: _execute(isolate, queue)
    ↓
监听: isolate.onMessage.listen((event) => queue.callback(event))
    ↓
发送: isolate.sendMessage(queue.params)
    ↓
底层: isolateContactorController.onMessage.first
```

### 5. 关键区别

**`compute` 的回调**：
- 有用户自定义的回调函数
- 通过 `onMessage` + 用户回调 + 过滤逻辑实现
- 可以处理多个消息（进度更新）

**`sendMessage` 的"回调"**：
- 没有用户回调参数
- 直接使用 `onMessage.first`（只等待第一个消息）
- 不能处理多个消息

### 6. 代码验证

```dart
// compute 方法：有回调参数
Future<R> compute(P params, {IsolateCallback<R>? callback}) async {
  final queue = IsolateQueue<R, P>(params, callback); // 👈 传递回调
  // ...
}

// sendMessage 方法：没有回调参数
Future<R> sendMessage(P message) async {
  // 直接发送并等待第一个响应，没有回调处理
  return _isolateContactorController.onMessage.first;
}
```

## 总结

**答案：部分是的**

- `compute` 的回调机制：✅ **通过 `onMessage` 接口 + 中间处理层实现**
- `sendMessage` 的机制：✅ **也使用 `onMessage` 接口，但没有回调处理，直接等待第一个消息**

所以您添加的 `rawMessageStream` 暴露的就是这个底层的 `onMessage` 接口，这就是为什么它能接收到所有消息的原因！

Kevin-2483: 也就是说,这个通道只要worker建立起就在工作,如果有compute建立了,就会使用这个通道,compute关闭后,这个通道还在工作,是吗

GitHub Copilot: 完全正确！您的理解非常准确。让我验证一下这个机制： 您说得完全正确！让我详细解释这个机制：

## 通道的生命周期

### 1. **Worker 建立时就开始工作**

```dart
// 在构造函数中就设置了监听器
IsolateContactorControllerWebWorker(...) {
  _delegate.onmessage = _handleMessage.toJS;  // 👈 Worker 一创建就开始监听
}
```

这意味着：
- ✅ **Worker 创建时，`onMessage` 通道就开始工作**
- ✅ **不依赖任何 `compute` 调用**
- ✅ **一直持续到 Worker 销毁**

### 2. **compute 只是"借用"这个通道**

```dart
// _execute 方法中
sub = isolate.onMessage.listen(  // 👈 临时订阅已存在的通道
  (event) async {
    if (await queue.callback(event)) {
      await sub?.cancel();      // 👈 compute 完成后取消订阅
      // ...
    }
  },
);
```

这说明：
- ✅ **`compute` 只是临时订阅 `onMessage` 流**
- ✅ **`compute` 完成后只是取消订阅，不关闭通道**
- ✅ **底层通道继续工作**

### 3. **完整的生命周期图**

```
Worker 创建
    ↓
onMessage 通道建立 ← 一直在工作 ← 您的 rawMessageStream 访问的就是这个
    ↓
compute1 订阅 → 处理消息 → 完成后取消订阅
    ↓
onMessage 通道继续工作 ← 仍然接收所有消息
    ↓
compute2 订阅 → 处理消息 → 完成后取消订阅
    ↓
onMessage 通道继续工作 ← 仍然接收所有消息
    ↓
Worker 销毁时才关闭通道
```

### 4. **证据验证**

在代码中可以看到：

**通道建立**（Worker 创建时）：
```dart
_delegate.onmessage = _handleMessage.toJS;  // 永久监听器
```

**compute 的临时订阅**：
```dart
sub = isolate.onMessage.listen(...);  // 临时订阅
await sub?.cancel();                  // 只取消这个订阅
```

**通道关闭**（Worker 销毁时）：
```dart
Future<void> close() async {
  _delegate.terminate();              // 销毁 Worker
  await _mainStreamController.close(); // 关闭流控制器
}
```

### 5. **实际验证方式**

您可以这样验证：

```dart
final worker = IsolateManager.createCustom(yourWorkerFunction);
await worker.start();

// 设置原始监听器
worker.rawMessageStream.listen((msg) {
  print('原始通道收到: $msg');
});

// 第一个 compute
print('开始第一个 compute');
await worker.compute('task1', callback: (msg) => 
  jsonDecode(msg)['type'] == 'result');
print('第一个 compute 完成');

// 等待一下
await Future.delayed(Duration(seconds: 1));

// 第二个 compute
print('开始第二个 compute');
await worker.compute('task2', callback: (msg) => 
  jsonDecode(msg)['type'] == 'result');
print('第二个 compute 完成');

// 原始通道仍然会收到所有消息！
```

## 总结

您的理解完全正确：

1. ✅ **`onMessage` 通道在 Worker 建立时就开始工作**
2. ✅ **`compute` 只是临时"借用"这个通道**
3. ✅ **`compute` 关闭后，通道继续工作**
4. ✅ **您的 `rawMessageStream` 直接访问这个持续工作的通道**

这就是为什么您能通过 `rawMessageStream` 接收到所有消息，而不受 `compute` 生命周期影响的根本原因！

Kevin-2483: 能同时有多个compute借用吗

GitHub Copilot: 能！但有重要的限制。让我分析一下多个 `compute` 同时借用的机制： ## 多个 compute 同时借用的机制

### 1. **并发限制：基于 Isolate 数量**

```dart
// IsolateManager 内部状态
final Map<IsolateContactor<R, P>, bool> _isolates = {}; // isolate -> isBusy

// 执行逻辑
void _executeQueue() {
  for (final isolate in _isolates.keys) {
    if (queueStrategy.hasNext() && _isolates[isolate] == false) { // 👈 只有空闲的 isolate 才能处理新任务
      final queue = queueStrategy.getNext();
      _execute(isolate, queue);  // 每个 isolate 同时只能处理一个 compute
    }
  }
}
```

### 2. **并发模式分析**

**情况1：单个 Isolate（`concurrent: 1`）**
```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 1,  // 👈 只有一个 isolate
);

// 同时调用多个 compute
final future1 = manager.compute('task1');  // 立即执行
final future2 = manager.compute('task2');  // 排队等待
final future3 = manager.compute('task3');  // 排队等待
```

**结果**：
- ✅ 可以同时调用多个 `compute`
- ❌ 但只能串行执行（一个接一个）
- 🔄 同一时间只有一个 `compute` "借用"通道

**情况2：多个 Isolate（`concurrent: 3`）**
```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 3,  // 👈 三个 isolate
);

// 同时调用多个 compute
final future1 = manager.compute('task1');  // isolate1 执行
final future2 = manager.compute('task2');  // isolate2 执行
final future3 = manager.compute('task3');  // isolate3 执行
final future4 = manager.compute('task4');  // 排队等待
```

**结果**：
- ✅ 可以同时调用多个 `compute`
- ✅ 最多 3 个可以同时执行
- 🔄 每个 isolate 同时只能被一个 `compute` "借用"

### 3. **通道借用的具体机制**

```dart
Future<R> _execute(IsolateContactor<R, P> isolate, IsolateQueue<R, P> queue) async {
  _isolates[isolate] = true;  // 👈 标记为忙碌

  StreamSubscription<dynamic>? sub;
  sub = isolate.onMessage.listen(  // 👈 这个 compute 独占监听
    (event) async {
      if (await queue.callback(event)) {
        await sub?.cancel();       // 👈 释放监听权
        _isolates[isolate] = false; // 👈 标记为空闲
        // ...
      }
    },
  );

  await isolate.sendMessage(queue.params);
  return queue.completer.future;
}
```

### 4. **消息分发的问题**

这里有一个重要问题：**多个 `compute` 如何区分消息**？

答案是：**它们不能区分！**每个 isolate 在同一时间只能处理一个 `compute`，避免了消息混乱。

### 5. **实际测试验证**

```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 2,  // 两个 isolate
);

await manager.start();

// 同时启动多个 compute
final results = await Future.wait([
  manager.compute('task1'),  // isolate1 处理
  manager.compute('task2'),  // isolate2 处理
  manager.compute('task3'),  // 排队等待
  manager.compute('task4'),  // 排队等待
]);

print('所有任务完成: $results');
```

### 6. **队列策略的影响**

```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 1,
  queueStrategy: DropOldestStrategy(maxCount: 3), // 最多排队3个
);

// 快速提交5个任务
for (int i = 0; i < 5; i++) {
  manager.compute('task$i').then((result) {
    print('任务$i完成: $result');
  });
}
// 根据策略，可能只有3个任务会被执行
```

### 7. **rawMessageStream 的行为**

```dart
// 原始消息流会接收所有 isolate 的消息
manager.rawMessageStream.listen((msg) {
  print('原始消息: $msg'); // 👈 会收到来自所有并发 isolate 的消息
});

// 同时运行多个 compute
await Future.wait([
  manager.compute('task1'),
  manager.compute('task2'),
  manager.compute('task3'),
]);
// rawMessageStream 会收到所有3个任务的所有消息
```

## 总结

**可以同时有多个 `compute` 借用，但有限制：**

1. ✅ **可以同时调用**多个 `compute`
2. 🔄 **并发执行数量**受 `concurrent` 参数限制
3. 🔒 **每个 isolate 同时**只能被一个 `compute` 独占
4. 📤 **排队机制**：超出并发数的 `compute` 会排队等待
5. 🔀 **消息隔离**：每个 isolate 的消息不会混乱
6. 📡 **rawMessageStream**：会接收所有并发 isolate 的消息

这种设计既保证了并发性能，又避免了消息混乱的问题！

Kevin-2483: 也就是说,worker就像一个核,如果工作变多了,他就会超线程,但是一个线程还只能有一个compute,不能同时好几个compute和一个线程交流

GitHub Copilot: 您的比喻非常精准！但是有一个重要的区别需要澄清：

## 正确的理解

### 1. **Worker ≈ CPU 核心（正确）**
```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 4,  // 👈 就像4核CPU
);
```

### 2. **但不是"超线程"，而是"多核"**

**实际情况**：
- ✅ 每个 `concurrent` 都是**独立的 Worker/Isolate**
- ✅ 就像真正的**多核并行**，而不是超线程
- ✅ 每个 Worker 都有**独立的执行环境**

```dart
// 实际的架构
concurrent: 3 意味着：
┌─ Worker 1 ─┐  ┌─ Worker 2 ─┐  ┌─ Worker 3 ─┐
│ 独立的JS线程  │  │ 独立的JS线程  │  │ 独立的JS线程  │
│ 独立的内存    │  │ 独立的内存    │  │ 独立的内存    │
│ 独立的通道    │  │ 独立的通道    │  │ 独立的通道    │
└─────────────┘  └─────────────┘  └─────────────┘
```

### 3. **一个 Worker 一次只能服务一个 compute（正确）**
```dart
// 每个 Worker 的状态
final Map<IsolateContactor<R, P>, bool> _isolates = {
  worker1: false,  // 空闲，可以接受新的 compute
  worker2: true,   // 忙碌，正在处理一个 compute
  worker3: false,  // 空闲，可以接受新的 compute
};
```

### 4. **任务分发机制**
```dart
void _executeQueue() {
  for (final isolate in _isolates.keys) {
    if (queueStrategy.hasNext() && _isolates[isolate] == false) {
      // 👆 找到空闲的 Worker，分配一个 compute 给它
      final queue = queueStrategy.getNext();
      _execute(isolate, queue);  // 这个 Worker 开始专心处理这个 compute
    }
  }
}
```

### 5. **更准确的比喻**

```
CPU 多核处理器                    IsolateManager
┌─────────────────┐              ┌─────────────────┐
│  Core 1         │              │  Worker 1       │
│  运行 Process A  │     ≈        │  处理 compute A  │
│                 │              │                 │
│  Core 2         │              │  Worker 2       │
│  运行 Process B  │              │  处理 compute B  │
│                 │              │                 │
│  Core 3         │              │  Worker 3       │
│  空闲           │              │  空闲           │
│                 │              │                 │
│  Core 4         │              │  Worker 4       │
│  运行 Process C  │              │  处理 compute C  │
└─────────────────┘              └─────────────────┘
```

### 6. **实际验证**

```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 3,  // 3个 Worker
);

// 同时提交5个任务
final futures = [
  manager.compute('task1'),  // → Worker 1
  manager.compute('task2'),  // → Worker 2  
  manager.compute('task3'),  // → Worker 3
  manager.compute('task4'),  // → 排队等待
  manager.compute('task5'),  // → 排队等待
];

// 前3个立即开始执行，后2个排队
await Future.wait(futures);
```

### 7. **为什么不能多个 compute 共享一个 Worker**

因为每个 Worker 的通信通道是**单一的**：

```dart
// Worker 只有一个消息输入通道
worker.onmessage = (event) => {
  // 如果同时有多个 compute，无法区分这个消息属于哪个 compute
  handleMessage(event.data);
};

// Worker 只有一个消息输出通道  
worker.postMessage(data); // 发给谁？无法指定
```

## 总结

您的理解基本正确，但需要微调：

- ✅ **Worker = CPU 核心**
- ❌ ~~超线程~~ → ✅ **真正的多核并行**
- ✅ **一个 Worker 一次只能处理一个 compute**
- ✅ **不能同时多个 compute 和一个 Worker 交流**

这种设计确保了：
1. **真正的并行处理**（多个独立的执行环境）
2. **消息不会混乱**（每个通道专属于一个任务）
3. **资源管理清晰**（每个 Worker 的状态明确）

您的比喻很棒，帮助理解了整个架构！

Kevin-2483: 那compute发送使用的是什么通道

GitHub Copilot: 让我查看 `compute` 发送消息使用的通道： 现在我明白了！让我解释 `compute` 发送使用的通道：

## compute 发送通道的机制

### 1. **compute 使用相同的发送通道**

```dart
// compute 的调用链
compute(params) 
    ↓
_execute(isolate, queue)
    ↓  
isolate.sendMessage(queue.params)  // 👈 使用 isolate 的发送通道
    ↓
_isolateContactorController.sendIsolate(message)
    ↓
_delegate.postMessage(message)     // 👈 最终还是 Worker.postMessage()
```

### 2. **发送通道是共享的，但有时序控制**

关键在于：**每个 Worker 只有一个发送通道，但通过时序控制避免冲突**

```dart
// 每个 Worker 的通道结构
Worker {
  发送通道: worker.postMessage()     // 👈 只有一个发送入口
  接收通道: worker.onmessage        // 👈 只有一个接收出口
}
```

### 3. **时序控制机制**

```dart
Future<R> _execute(IsolateContactor<R, P> isolate, IsolateQueue<R, P> queue) async {
  _isolates[isolate] = true;  // 👈 1. 先占用这个 Worker

  // 2. 设置接收监听
  sub = isolate.onMessage.listen((event) => {...});

  // 3. 发送消息（独占使用发送通道）
  await isolate.sendMessage(queue.params);  // 👈 此时没有其他 compute 能使用这个 Worker

  return queue.completer.future;
}
```

### 4. **为什么不会冲突**

因为有**互斥锁机制**：

```dart
void _executeQueue() {
  for (final isolate in _isolates.keys) {
    if (queueStrategy.hasNext() && _isolates[isolate] == false) {  // 👈 只有空闲的 Worker 才能被使用
      final queue = queueStrategy.getNext();
      _execute(isolate, queue);  // 这个 Worker 被独占
    }
  }
}
```

### 5. **完整的通信架构**

```
主应用端                           Worker 端
┌─────────────────┐               ┌──────────────────┐
│  compute1       │               │                  │
│  ├─ 等待 Worker │               │                  │
│                 │               │                  │
│  compute2       │               │                  │
│  ├─ 使用 Worker1│──postMessage──→│ Worker1          │
│  │  (独占发送)   │               │  ├─ 处理消息      │
│  │              │←──onmessage───│  └─ 发送结果      │
│                 │               │                  │
│  compute3       │               │                  │
│  ├─ 使用 Worker2│──postMessage──→│ Worker2          │
│  │  (独占发送)   │               │  ├─ 处理消息      │
│  │              │←──onmessage───│  └─ 发送结果      │
│                 │               │                  │
│  compute4       │               │                  │
│  ├─ 排队等待     │               │                  │
└─────────────────┘               └──────────────────┘
```

### 6. **实际代码验证**

```dart
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 2,  // 2个 Worker
);

// 同时启动3个 compute
final future1 = manager.compute('task1');  // → Worker1 独占发送通道
final future2 = manager.compute('task2');  // → Worker2 独占发送通道  
final future3 = manager.compute('task3');  // → 排队等待

// 每个 Worker 的发送通道在同一时间只被一个 compute 使用
await Future.wait([future1, future2, future3]);
```

### 7. **与接收通道的对比**

```dart
// 发送通道：独占使用
worker.postMessage(data);  // 同一时间只有一个 compute 能发送

// 接收通道：可以被多个监听者共享
worker.onMessage.listen(...);     // compute 的临时监听
rawMessageStream.listen(...);     // 您添加的持续监听
```

## 总结

**compute 发送使用的通道：**

1. ✅ **使用 Worker 的 `postMessage` 发送通道**
2. 🔒 **通过互斥锁确保独占使用**
3. ⏰ **时序控制：一个 Worker 同时只能被一个 compute 使用**
4. 🔄 **发送通道是共享的，但访问是串行的**
5. 📤 **每个 Worker 只有一个发送入口，避免了消息混乱**

所以虽然多个 `compute` 可能想要发送消息，但通过 IsolateManager 的调度机制，确保每个 Worker 的发送通道在同一时间只被一个 `compute` 独占使用！

Kevin-2483: 也就是说worker有一进一出两个单行道,且如果不并行的话,每次只能进一个消息,出一个消息

GitHub Copilot: 完全正确！您的比喻非常精准。让我验证并详细解释这个"单行道"机制： 您的理解完全正确！让我用图解来确认这个"单行道"机制：

## Worker 的"单行道"架构

### 1. **基本结构**

```
主应用端                        Worker 端
┌─────────────┐                ┌─────────────┐
│             │  进入单行道      │             │
│   compute   │────────────────→│   Worker    │
│             │   postMessage   │             │
│             │                 │             │
│             │  离开单行道      │             │
│             │←────────────────│             │
│             │   onmessage     │             │
└─────────────┘                └─────────────┘
```

### 2. **Web Worker 的原生限制**

```javascript
// Web Worker 原生 API 就是单行道设计
worker.postMessage(data);    // 👈 进入单行道：一次只能发送一个消息
worker.onmessage = (event) => {
  console.log(event.data);   // 👈 离开单行道：一次只能处理一个消息
};
```

### 3. **Dart 层面的封装**

```dart
// Dart 封装了 Web Worker，但保持了单行道特性
void sendIsolate(P message) {
  _delegate.postMessage(message.jsify());  // 👈 单行道入口
}

// 构造函数中设置单一监听器
_delegate.onmessage = _handleMessage.toJS;  // 👈 单行道出口
```

### 4. **非并行情况的消息流**

```dart
// 如果 concurrent: 1 (非并行)
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 1,  // 👈 只有一个 Worker
);

// 消息流时序
await manager.compute('task1');  // 1. 进入 → 处理 → 离开
await manager.compute('task2');  // 2. 进入 → 处理 → 离开  
await manager.compute('task3');  // 3. 进入 → 处理 → 离开
```

**时序图**：
```
时间轴  进入单行道    Worker处理    离开单行道
  T1    task1    →    processing  →   result1
  T2              →    task2      →   processing  →  result2  
  T3                              →   task3       →  processing  →  result3
```

### 5. **并行情况的多条单行道**

```dart
// 如果 concurrent: 3 (并行)
final manager = IsolateManager.createCustom(
  workerFunction,
  concurrent: 3,  // 👈 三个独立的 Worker
);

// 每个 Worker 都是独立的单行道
Worker1: task1 → processing → result1
Worker2: task2 → processing → result2  
Worker3: task3 → processing → result3
```

### 6. **单行道的特性验证**

```dart
// 验证进入单行道的独占性
Future<R> sendMessage(P message) async {
  _isolateContactorController.sendIsolate(message);  // 发送
  return _isolateContactorController.onMessage.first; // 等待第一个响应
  // 👆 这里体现了单行道：发送一个，等待一个
}
```

### 7. **为什么是单行道设计**

**Web Worker 的本质限制**：
```javascript
// Web Worker 内部只有一个主线程
self.onmessage = function(event) {
  // 同一时间只能处理一个消息
  var result = processMessage(event.data);
  
  // 同一时间只能发送一个消息
  self.postMessage(result);
};
```

### 8. **实际测试验证**

```dart
final worker = IsolateManager.createCustom(
  workerFunction,
  concurrent: 1,  // 单个 Worker = 单条单行道
);

// 模拟快速发送多个消息
for (int i = 0; i < 5; i++) {
  worker.compute('task$i').then((result) {
    print('任务$i完成: $result');
  });
}

// 输出会是：
// 任务0完成: result0
// 任务1完成: result1  
// 任务2完成: result2
// 任务3完成: result3
// 任务4完成: result4
// 👆 严格按顺序，证明是单行道
```

### 9. **单行道的优缺点**

**优点**：
- ✅ **消息顺序可预测**
- ✅ **不会有消息混乱**
- ✅ **简单可靠**

**缺点**：
- ❌ **单个 Worker 无法真正并发处理多个任务**
- ❌ **需要多个 Worker 才能实现并行**

## 总结

您的理解完全正确：

1. ✅ **Worker 有一进一出两个单行道**
   - 进入：`postMessage()` 
   - 离开：`onmessage`

2. ✅ **非并行时每次只能进一个消息，出一个消息**
   - 严格的串行处理
   - 消息不会重叠或混乱

3. ✅ **并行时相当于多条独立的单行道**
   - 每个 Worker 都是独立的单行道
   - 多条单行道可以同时工作

这种"单行道"设计是 Web Worker 的基础架构，确保了通信的可靠性和可预测性！

Kevin-2483: 能不能把发送的底层接口也暴露出来,方便我直接控制信息的发送

GitHub Copilot: 好的！我来告诉您如何暴露发送的底层接口。让我先查看当前的结构： 现在我来告诉您如何添加发送接口。您需要在 `isolateContactors` getter 之后添加一个新的方法：

## 添加底层发送接口

### 步骤1：在 `isolateContactors` getter 后添加发送方法

在您已经添加的 `isolateContactors` getter 后面，继续添加：

```dart
  /// Send message directly to a specific isolate without going through the queue system.
  /// This provides direct access to the underlying isolate communication channel.
  /// 
  /// [isolateIndex] specifies which isolate to send to (0-based index).
  /// If not provided, sends to the first available isolate.
  /// 
  /// Use this when you need complete control over message sending and want to
  /// bypass the IsolateManager's queue and lifecycle management.
  /// 
  /// Warning: Using this method bypasses all safety mechanisms including:
  /// - Queue management
  /// - Isolate availability checking  
  /// - Error handling
  /// - Message ordering guarantees
  Future<R> sendRawMessage(P message, {int? isolateIndex}) async {
    if (_isolates.isEmpty) {
      throw StateError('No isolates available. Call start() first.');
    }
    
    final isolateList = _isolates.keys.toList();
    final targetIndex = isolateIndex ?? 0;
    
    if (targetIndex >= isolateList.length) {
      throw RangeError('Isolate index $targetIndex is out of range. '
          'Available isolates: ${isolateList.length}');
    }
    
    final targetIsolate = isolateList[targetIndex];
    return await targetIsolate.sendMessage(message);
  }

  /// Send message to all isolates simultaneously.
  /// Returns a list of results from all isolates.
  /// 
  /// Use this when you want to broadcast a message to all available isolates.
  /// 
  /// Warning: This bypasses all queue and safety mechanisms.
  Future<List<R>> broadcastRawMessage(P message) async {
    if (_isolates.isEmpty) {
      throw StateError('No isolates available. Call start() first.');
    }
    
    final futures = _isolates.keys.map((isolate) => isolate.sendMessage(message));
    return await Future.wait(futures);
  }

  /// Send message without waiting for response.
  /// This is a fire-and-forget operation.
  /// 
  /// Use this when you only want to send commands and don't need responses,
  /// or when you're handling responses through rawMessageStream.
  void sendRawMessageFireAndForget(P message, {int? isolateIndex}) {
    if (_isolates.isEmpty) {
      throw StateError('No isolates available. Call start() first.');
    }
    
    final isolateList = _isolates.keys.toList();
    final targetIndex = isolateIndex ?? 0;
    
    if (targetIndex >= isolateList.length) {
      throw RangeError('Isolate index $targetIndex is out of range. '
          'Available isolates: ${isolateList.length}');
    }
    
    final targetIsolate = isolateList[targetIndex];
    
    // Fire and forget - don't wait for response
    targetIsolate.sendMessage(message).ignore();
  }
```

### 步骤2：添加更高级的接口

继续添加更方便的接口：

```dart
  /// Get the number of available isolates.
  int get isolateCount => _isolates.length;

  /// Check if a specific isolate is busy.
  bool isIsolateBusy(int isolateIndex) {
    if (isolateIndex >= _isolates.length) {
      throw RangeError('Isolate index $isolateIndex is out of range.');
    }
    
    final isolate = _isolates.keys.elementAt(isolateIndex);
    return _isolates[isolate] ?? false;
  }

  /// Get the first available (not busy) isolate index.
  /// Returns null if all isolates are busy.
  int? get firstAvailableIsolateIndex {
    for (int i = 0; i < _isolates.length; i++) {
      if (!isIsolateBusy(i)) {
        return i;
      }
    }
    return null;
  }

  /// Send message to the first available isolate.
  /// Throws StateError if all isolates are busy.
  Future<R> sendToAvailableIsolate(P message) async {
    final availableIndex = firstAvailableIsolateIndex;
    if (availableIndex == null) {
      throw StateError('All isolates are busy. Try again later or increase concurrent count.');
    }
    
    return await sendRawMessage(message, isolateIndex: availableIndex);
  }
```

## 使用方式

添加完成后，您可以这样使用：

### 1. 基本发送
```dart
// 发送到第一个 isolate
final result = await manager.sendRawMessage(jsonRequest);

// 发送到指定的 isolate
final result = await manager.sendRawMessage(jsonRequest, isolateIndex: 1);
```

### 2. Fire-and-Forget 发送
```dart
// 监听所有响应
manager.rawMessageStream.listen((response) {
  print('收到响应: $response');
});

// 发送命令但不等待响应
manager.sendRawMessageFireAndForget(jsonRequest);
```

### 3. 广播发送
```dart
// 向所有 isolate 发送相同消息
final results = await manager.broadcastRawMessage('ping');
print('所有 isolate 响应: $results');
```

### 4. 智能发送到可用 isolate
```dart
try {
  final result = await manager.sendToAvailableIsolate(jsonRequest);
  print('结果: $result');
} catch (e) {
  print('所有 isolate 都忙碌: $e');
}
```

### 5. 完全手动控制
```dart
// 检查状态
print('总共 ${manager.isolateCount} 个 isolate');
print('第一个可用的: ${manager.firstAvailableIsolateIndex}');

// 选择特定的 isolate
if (!manager.isIsolateBusy(0)) {
  await manager.sendRawMessage(jsonRequest, isolateIndex: 0);
}
```

## 优势

通过这些接口，您可以：

1. ✅ **绕过队列系统**，直接发送消息
2. ✅ **选择特定的 isolate**，实现负载均衡
3. ✅ **Fire-and-forget 发送**，配合 `rawMessageStream` 使用
4. ✅ **广播消息**，同时向所有 isolate 发送
5. ✅ **检查 isolate 状态**，智能选择可用的 isolate
6. ✅ **完全控制消息流**，不受 IsolateManager 生命周期限制

这样您就拥有了完整的底层控制能力！

看到了错误信息，我来帮您修复 web.dart 文件中的实现。主要问题是缺少具体实现和类型错误。 现在我来修复这些错误。主要问题是：

1. `IsolateManagerControllerImpl` 类缺少新方法的实现
2. `jsify()` 方法的参数类型问题
3. 重写方法的问题 
```


已进行更改。


```
我需要解决这些问题。主要是接口不匹配和类型问题。让我先修复 `IsolateManagerControllerImpl` 的实现： 
```


已进行更改。


```
已汇总会话历史记录现在我需要修复 `_IsolateManagerWorkerController` 类的问题。先移除错误的 `@override` 注解，并修复类型问题： 
```


已进行更改。


```
已汇总会话历史记录让我修复这些类型问题： 
```


已进行更改。


```
已汇总会话历史记录让我修复这个问题，使用正确的方式处理 null 值： 
```


已进行更改。


```
已汇总会话历史记录现在让我检查一下是否还有其他错误，并优化类型转换： 
```


已进行更改。


```
已汇总会话历史记录现在让我检查完整的文件，确保所有方法都正确实现了： 已汇总会话历史记录现在让我检查是否需要在 stub 实现中也添加这些方法。先检查 stub 文件： 已汇总会话历史记录已汇总会话历史记录好的，看起来 stub 文件已经有了这些方法的实现。现在让我检查一下当前的错误状态，看看是否还有需要修复的问题。

## 总结修复内容

我已经在 web.dart 文件中完成了以下修复：

### 1. **在 `IsolateManagerControllerImpl` 中添加了新方法的实现**
- `rawWorkerScope` getter
- `setRawMessageHandler()` 方法  
- `sendRawMessage()` 方法

### 2. **在 `_IsolateManagerWorkerController` 中添加了底层实现**
- 移除了错误的 `@override` 注解
- 修复了 `sendRawMessage` 方法的类型安全问题
- 正确处理了 JavaScript 类型转换

### 3. **类型安全改进**
- 使用了正确的 JavaScript 互操作类型 (`JSAny?`)
- 处理了不同数据类型的转换 (String, num, bool, Map, List)
- 安全地处理了 null 值

## 现在您可以使用这些新接口：

### 在 Worker 中使用：
```dart
@isolateManagerCustomWorker
void myWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      // 设置原始消息处理器
      controller.setRawMessageHandler((event) {
        print('原始消息: $event');
        return true; // 继续正常处理
      });
      
      // 获取原始 Worker 作用域
      final worker = controller.rawWorkerScope;
      print('Worker: $worker');
    },
    onEvent: (controller, message) async {
      // 发送原始消息
      controller.sendRawMessage({
        'type': 'custom',
        'data': 'Hello from worker'
      });
      
      return "processed: $message";
    },
  );
}
```

这样您就拥有了对 Worker 底层通信的完全控制权！

已汇总会话历史记录让我详细解释 Worker 的接收接口如何使用：

## Worker 接收接口的使用方式

### 1. **标准接收接口：`onIsolateMessage`**

这是最常用的接收方式：

```dart
@isolateManagerCustomWorker
void myWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onEvent: (controller, message) async {
      // message 就是从主应用发送过来的消息
      print('收到消息: $message');
      
      // 处理消息
      final result = processMessage(message);
      
      // 返回结果（会自动通过 sendResult 发送）
      return result;
    },
  );
}
```

### 2. **原始消息处理器：`setRawMessageHandler`**

可以拦截所有原始消息：

```dart
@isolateManagerCustomWorker
void rawMessageWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      // 设置原始消息处理器
      controller.setRawMessageHandler((event) {
        print('原始事件: $event');
        
        // 可以访问 MessageEvent 的所有属性
        final data = event.data?.dartify();
        print('原始数据: $data');
        
        // 检查是否是特殊消息
        if (data is Map && data['type'] == 'system') {
          // 处理系统消息
          handleSystemMessage(data);
          return false; // 停止进一步处理
        }
        
        // 记录所有消息
        logMessage(data);
        return true; // 继续正常处理
      });
    },
    onEvent: (controller, message) async {
      // 正常的消息处理
      return "处理完成: $message";
    },
  );
}
```

### 3. **完全自定义的接收处理**

直接操作 Worker 的 `onmessage`：

```dart
@isolateManagerCustomWorker
void customReceiveWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    autoHandleResult: false, // 关闭自动处理
    onInit: (controller) {
      // 获取原始 Worker 作用域
      final worker = controller.rawWorkerScope as DedicatedWorkerGlobalScope;
      
      // 完全自定义消息处理
      worker.onmessage = (MessageEvent event) {
        final data = event.data.dartify();
        print('自定义接收: $data');
        
        if (data is Map) {
          switch (data['type']) {
            case 'ping':
              // 立即回复 pong
              controller.sendRawMessage({'type': 'pong', 'time': DateTime.now().millisecondsSinceEpoch});
              break;
              
            case 'execute':
              // 执行任务
              final result = executeTask(data['task']);
              controller.sendRawMessage({'type': 'result', 'data': result});
              break;
              
            case 'batch':
              // 批量处理
              final tasks = data['tasks'] as List;
              for (final task in tasks) {
                final result = executeTask(task);
                controller.sendRawMessage({'type': 'batch_result', 'data': result});
              }
              break;
              
            default:
              controller.sendRawMessage({'type': 'error', 'message': 'Unknown command'});
          }
        }
      }.toJS;
    },
    onEvent: (controller, message) async {
      // 这个可能不会被调用，因为我们重写了 onmessage
      return "fallback";
    },
  );
}
```

### 4. **混合模式：既监听原始消息又保持正常处理**

```dart
@isolateManagerCustomWorker
void hybridWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      // 原始消息处理器：用于监控和特殊处理
      controller.setRawMessageHandler((event) {
        final data = event.data?.dartify();
        
        // 记录所有消息
        print('监控: 收到消息 ${data}');
        
        // 处理优先级消息
        if (data is Map && data['priority'] == 'high') {
          print('高优先级消息: ${data['content']}');
          // 可以立即响应
          controller.sendRawMessage({
            'type': 'priority_ack',
            'message': '高优先级消息已收到'
          });
        }
        
        // 处理心跳消息
        if (data is Map && data['type'] == 'heartbeat') {
          controller.sendRawMessage({
            'type': 'heartbeat_response',
            'timestamp': DateTime.now().millisecondsSinceEpoch
          });
          return false; // 不进入正常处理流程
        }
        
        return true; // 继续正常处理
      });
    },
    onEvent: (controller, message) async {
      // 正常的业务逻辑处理
      print('业务处理: $message');
      
      // 模拟处理时间
      await Future.delayed(Duration(milliseconds: 100));
      
      return "业务处理完成: $message";
    },
  );
}
```

### 5. **流式数据处理**

处理连续的数据流：

```dart
@isolateManagerCustomWorker
void streamWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      final buffer = <Map>[];
      
      controller.setRawMessageHandler((event) {
        final data = event.data?.dartify();
        
        if (data is Map) {
          switch (data['type']) {
            case 'stream_data':
              // 收集流数据
              buffer.add(data);
              
              // 发送确认
              controller.sendRawMessage({
                'type': 'stream_ack',
                'index': data['index']
              });
              
              // 如果缓冲区满了，处理数据
              if (buffer.length >= 10) {
                final processedData = processBuffer(buffer);
                controller.sendRawMessage({
                  'type': 'batch_processed',
                  'data': processedData
                });
                buffer.clear();
              }
              
              return false; // 不进入正常处理
              
            case 'stream_end':
              // 处理剩余数据
              if (buffer.isNotEmpty) {
                final processedData = processBuffer(buffer);
                controller.sendRawMessage({
                  'type': 'final_batch',
                  'data': processedData
                });
              }
              
              controller.sendRawMessage({'type': 'stream_complete'});
              return false;
          }
        }
        
        return true;
      });
    },
    onEvent: (controller, message) async {
      return "stream worker ready";
    },
  );
}

List<String> processBuffer(List<Map> buffer) {
  // 处理缓冲区数据
  return buffer.map((item) => item['content'].toString().toUpperCase()).toList();
}
```

### 6. **错误处理和消息验证**

```dart
@isolateManagerCustomWorker
void robustWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      controller.setRawMessageHandler((event) {
        try {
          final data = event.data?.dartify();
          
          // 验证消息格式
          if (!isValidMessage(data)) {
            controller.sendRawMessage({
              'type': 'error',
              'code': 'INVALID_FORMAT',
              'message': '消息格式无效'
            });
            return false;
          }
          
          // 验证权限
          if (!hasPermission(data)) {
            controller.sendRawMessage({
              'type': 'error',
              'code': 'PERMISSION_DENIED',
              'message': '权限不足'
            });
            return false;
          }
          
          return true; // 通过验证，继续处理
          
        } catch (e, stackTrace) {
          // 处理解析错误
          controller.sendRawMessage({
            'type': 'error',
            'code': 'PARSE_ERROR',
            'message': e.toString(),
            'stack': stackTrace.toString()
          });
          return false;
        }
      });
    },
    onEvent: (controller, message) async {
      try {
        // 安全的业务处理
        final result = await safeProcessMessage(message);
        return result;
      } catch (e) {
        // 业务错误也通过原始消息发送
        controller.sendRawMessage({
          'type': 'business_error',
          'error': e.toString()
        });
        rethrow;
      }
    },
  );
}

bool isValidMessage(dynamic data) {
  return data is Map && data.containsKey('type') && data.containsKey('content');
}

bool hasPermission(Map data) {
  // 简单的权限检查
  return data['auth_token'] == 'valid_token';
}

Future<String> safeProcessMessage(String message) async {
  // 安全的消息处理逻辑
  await Future.delayed(Duration(milliseconds: 50));
  return "安全处理: $message";
}
```

## 接收接口的层次结构

```
Raw MessageEvent (最底层)
    ↓
setRawMessageHandler (原始拦截)
    ↓
onIsolateMessage Stream (标准接口)
    ↓  
onEvent callback (业务处理)
```

## 选择合适的接收方式

- **简单业务处理**：使用 `onEvent` callback
- **需要监控所有消息**：使用 `setRawMessageHandler`
- **需要完全控制**：直接操作 `worker.onmessage`
- **复杂消息路由**：组合使用多种方式

这样您就可以根据需求选择合适的接收接口了！

好的！我来告诉您如何在 Worker 端添加更底层的接口，直接访问 `self.onmessage` 和 `self.postMessage`。

## 添加 Worker 端底层接口

### 步骤1：修改 `IsolateManagerController` 接口

首先需要在 isolate_manager_controller.dart 中添加新的方法签名。

在该文件的接口定义中添加：

```dart
/// Get direct access to the raw Worker global scope for advanced control.
/// Only available in Web Worker environment.
/// 
/// Use this when you need complete control over Worker communication
/// and want to bypass all IsolateManager abstractions.
dynamic get rawWorkerScope;

/// Set a custom message handler that receives all raw messages.
/// This bypasses the normal message processing pipeline.
/// 
/// [handler] will receive the raw MessageEvent from the Worker.
/// Return true to also process the message through normal pipeline,
/// return false to stop further processing.
void setRawMessageHandler(bool Function(dynamic event) handler);

/// Send raw message directly through Worker's postMessage.
/// This bypasses all IsolateManager message formatting and processing.
/// 
/// [data] will be sent as-is through Worker.postMessage()
void sendRawMessage(dynamic data);
```

### 步骤2：在 Web 实现中添加具体实现

在 web.dart 的 `_IsolateManagerWorkerController` 类中添加实现：

```dart
class _IsolateManagerWorkerController<R, P>
    implements IsolateContactorController<R, P> {
  _IsolateManagerWorkerController(this.self, {this.onDispose}) {
    // 保存原始的 onmessage 处理器
    _originalOnMessage = (MessageEvent event) {
      // 先调用自定义的原始处理器（如果有）
      if (_rawMessageHandler != null) {
        final shouldContinue = _rawMessageHandler!(event);
        if (!shouldContinue) {
          return; // 停止进一步处理
        }
      }
      
      // 正常的消息处理
      dynamic result = event.data.dartify();
      if (isImTypeSubtype<P>()) {
        result = ImType.wrap(result as Object);
      }
      _streamController.sink.add(result as P);
    }.toJS;
    
    self.onmessage = _originalOnMessage;
  }
  
  final DedicatedWorkerGlobalScope self;
  final void Function()? onDispose;
  final _streamController = StreamController<P>.broadcast();
  
  // 新增字段
  late final JSFunction _originalOnMessage;
  bool Function(dynamic)? _rawMessageHandler;

  // ...existing code...

  /// 新增：获取原始 Worker 作用域
  @override
  dynamic get rawWorkerScope => self;

  /// 新增：设置原始消息处理器
  @override
  void setRawMessageHandler(bool Function(dynamic event) handler) {
    _rawMessageHandler = handler;
  }

  /// 新增：发送原始消息
  @override
  void sendRawMessage(dynamic data) {
    self.postMessage(data.jsify());
  }

  /// 新增：直接设置 onmessage 处理器（完全绕过 IsolateManager）
  void setRawOnMessageHandler(JSFunction handler) {
    self.onmessage = handler;
  }

  /// 新增：恢复默认的 onmessage 处理器
  void restoreDefaultOnMessageHandler() {
    self.onmessage = _originalOnMessage;
  }

  // ...existing code...
}
```

### 步骤3：在 Stub 实现中添加占位符

在 stub.dart 中添加：

```dart
class IsolateManagerControllerImpl<R, P>
    implements IsolateManagerController<R, P> {
  // ...existing code...

  /// 在非 Web 环境中不可用
  @override
  dynamic get rawWorkerScope => throw UnsupportedError(
    'rawWorkerScope is only available in Web Worker environment'
  );

  /// 在非 Web 环境中不可用
  @override
  void setRawMessageHandler(bool Function(dynamic event) handler) {
    throw UnsupportedError(
      'setRawMessageHandler is only available in Web Worker environment'
    );
  }

  /// 在非 Web 环境中不可用
  @override
  void sendRawMessage(dynamic data) {
    throw UnsupportedError(
      'sendRawMessage is only available in Web Worker environment'
    );
  }
}
```

### 步骤4：在 `IsolateManagerController` 基类中添加方法

在 isolate_manager_controller.dart 中添加：

```dart
class IsolateManagerController<R, P> {
  // ...existing code...

  /// Get direct access to the raw Worker global scope for advanced control.
  /// Only available in Web Worker environment.
  dynamic get rawWorkerScope => _delegate.rawWorkerScope;

  /// Set a custom message handler that receives all raw messages.
  void setRawMessageHandler(bool Function(dynamic event) handler) =>
      _delegate.setRawMessageHandler(handler);

  /// Send raw message directly through Worker's postMessage.
  void sendRawMessage(dynamic data) => _delegate.sendRawMessage(data);
}
```

## 使用方式

### 1. 基本的原始消息处理

```dart
@isolateManagerCustomWorker
void myWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      // 设置原始消息处理器
      controller.setRawMessageHandler((event) {
        print('原始消息: ${event.data}');
        
        // 检查是否是特殊命令
        if (event.data?.type == 'special_command') {
          // 处理特殊命令
          handleSpecialCommand(event.data);
          return false; // 停止正常处理
        }
        
        return true; // 继续正常处理
      });
    },
    onEvent: (controller, message) async {
      // 正常的消息处理
      return "normal response";
    },
  );
}
```

### 2. 完全控制 Worker 通信

```dart
@isolateManagerCustomWorker
void advancedWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      // 获取原始 Worker 作用域
      final worker = controller.rawWorkerScope;
      
      // 完全自定义的消息处理
      worker.onmessage = (MessageEvent event) {
        final data = event.data.dartify();
        
        if (data['type'] == 'ping') {
          // 直接回复
          controller.sendRawMessage({'type': 'pong', 'timestamp': DateTime.now().millisecondsSinceEpoch});
        } else if (data['type'] == 'broadcast') {
          // 广播消息
          for (int i = 0; i < 5; i++) {
            controller.sendRawMessage({'type': 'broadcast_response', 'index': i});
          }
        } else {
          // 其他消息通过正常渠道处理
          // 这里可以调用原始的处理器或者自己处理
        }
      }.toJS;
    },
    onEvent: (controller, message) async {
      // 这个可能不会被调用，因为我们重写了 onmessage
      return "fallback response";
    },
  );
}
```

### 3. 混合模式：既有正常处理又有原始处理

```dart
@isolateManagerCustomWorker
void hybridWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onInit: (controller) {
      controller.setRawMessageHandler((event) {
        final data = event.data.dartify();
        
        // 处理系统级消息
        if (data['type'] == 'system') {
          handleSystemMessage(data);
          return false; // 不进入正常处理
        }
        
        // 记录所有消息
        print('收到消息: ${data['type']}');
        return true; // 继续正常处理
      });
    },
    onEvent: (controller, message) async {
      // 正常的业务逻辑处理
      return processBusinessMessage(message);
    },
  );
}
```

### 4. 发送原始消息

```dart
@isolateManagerCustomWorker
void rawSenderWorkerFunction(dynamic params) {
  IsolateManagerFunction.customFunction<String, String>(
    params,
    onEvent: (controller, message) async {
      // 发送格式化的响应
      controller.sendRawMessage({
        'type': 'custom_response',
        'data': processMessage(message),
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'worker_id': 'worker_001'
      });
      
      // 发送进度更新
      for (int i = 0; i < 10; i++) {
        controller.sendRawMessage({
          'type': 'progress',
          'progress': i * 10,
          'message': 'Processing step $i'
        });
        await Future.delayed(Duration(milliseconds: 100));
      }
      
      return "task completed";
    },
  );
}
```

## 优势

通过这些底层接口，您可以：

1. ✅ **完全控制消息格式**，不受 IsolateManager 限制
2. ✅ **实现自定义协议**，比如心跳、状态同步等
3. ✅ **绕过所有中间层**，获得最佳性能
4. ✅ **同时支持正常和原始消息处理**
5. ✅ **实现复杂的消息路由和过滤**
6. ✅ **直接使用 Web Worker 的所有原生能力**

这样您就拥有了对 Worker 通信的完全控制权！
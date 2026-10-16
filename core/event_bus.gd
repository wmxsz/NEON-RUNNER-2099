extends Node
## 全局事件总线（autoload）。
## 只承载跨模块的玩家动作语义；各子系统专属事件优先使用本地 signal，避免无消费者的全局广播。

signal jumped
signal slid

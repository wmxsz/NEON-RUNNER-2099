class_name U
extends Object
## 纯静态数学与随机数工具：阻尼、插值、范围随机和可复现的种子随机序列。

static func clampf(v: float, a: float, b: float) -> float:
        return 0.0 if v < a else (b if v > b else v)

static func lerpf(a: float, b: float, t: float) -> float:
        return a + (b - a) * t

## 帧率无关阻尼：1 - exp(-λ·dt)。
static func dampf(a: float, b: float, lambda: float, dt: float) -> float:
        return lerpf(a, b, 1.0 - exp(-lambda * dt))

static func randf_range(a: float, b: float) -> float:
        return a + randf() * (b - a)

static func randi_range(a: int, b: int) -> int:
        return floor(randf_range(a, b + 1))

static func choice(arr: Array) -> Variant:
        return arr[randi() % arr.size()]

## 标准 Mulberry32 确定性随机数生成器；固定种子由回归参考序列验证。
static func _imul32(a: int, b: int) -> int:
        # Emulate Math.imul modulo 2^32 without relying on a potentially overflowing
        # signed 64-bit product. The high-high term vanishes modulo 2^32.
        var a_low: int = a & 0xFFFF
        var a_high: int = (a >> 16) & 0xFFFF
        var b_low: int = b & 0xFFFF
        var b_high: int = (b >> 16) & 0xFFFF
        var low_product: int = a_low * b_low
        var cross_low: int = (a_high * b_low + a_low * b_high) & 0xFFFF
        return (low_product + (cross_low << 16)) & 0xFFFFFFFF

static func mulberry32(seed_i: int) -> Callable:
        # GDScript lambdas capture scalar locals by value. Keep mutable RNG state in
        # an Array (reference type), and mutate its element so successive calls advance.
        var state: Array[int] = [seed_i & 0xFFFFFFFF]
        return func() -> float:
                state[0] = (state[0] + 0x6D2B79F5) & 0xFFFFFFFF
                var t: int = state[0]
                t = U._imul32((t ^ (t >> 15)) & 0xFFFFFFFF, t | 1)
                var mixed: int = (t ^ (t >> 7)) & 0xFFFFFFFF
                var product: int = U._imul32(mixed, t | 61)
                t = (t ^ ((t + product) & 0xFFFFFFFF)) & 0xFFFFFFFF
                t = (t ^ (t >> 14)) & 0xFFFFFFFF
                return float(t) / 4294967296.0

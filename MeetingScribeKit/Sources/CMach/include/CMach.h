#ifndef CMACH_H
#define CMACH_H

#include <mach/mach.h>

/// Возвращает порт текущей задачи. Обёртка нужна, потому что глобальная переменная
/// `mach_task_self_` не является concurrency-safe с точки зрения Swift 6.
mach_port_t cmach_task_self(void);

#endif

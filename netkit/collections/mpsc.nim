

import std/math
import netkit/locks
import netkit/alloctor

type
  SigCounter* = ptr object of RootObj
    signalImpl*: proc (c: SigCounter) {.nimcall, gcsafe.}
    waitImpl*: proc (c: SigCounter): Natural {.nimcall, gcsafe.}

proc signal*(c: SigCounter) {.inline.} =
  c.signalImpl(c) 

proc wait*(c: SigCounter): Natural {.inline.} =
  c.waitImpl(c) 

type
  MpscQueue*[T] = object 
    writeLock: SpinLock
    data: ptr UncheckedArray[T]
    head: Natural
    tail: Natural 
    cap: Natural
    mask: Natural
    len: Natural
    counter: SigCounter
    counterAlloctor: Alloctor[SigCounter]

proc `=destroy`*[T](x: var MpscQueue[T]) = 
  deallocShared(x.data)
  x.counterAlloctor.dealloc(x.counter)

proc initMpscQueue*[T](counterAlloctor: Alloctor[SigCounter], cap: Natural = 4): MpscQueue[T] =
  assert isPowerOfTwo(cap)
  result.writeLock = initSpinLock()
  result.data = cast[ptr UncheckedArray[T]](allocShared0(sizeof(T) * cap))
  result.head = 0
  result.tail = 0
  result.cap = cap
  result.mask = cap - 1
  result.len = 0
  result.counterAlloctor = counterAlloctor
  result.counter = result.counterAlloctor.alloc()

proc tryAdd*[T](x: var MpscQueue[T], item: sink T): bool = 
  result = true
  withLock x.writeLock:
    let next = (x.tail + 1) and x.mask
    if unlikely(next == x.head):
      return false
    x.data[x.tail] = item
    x.tail = next
  fence()
  x.counter.signal()

proc add*[T](x: var MpscQueue[T], item: sink T) = 
  withLock x.writeLock:
    let next = (x.tail + 1) and x.mask
    while unlikely(next == x.head):
      cpuRelax()
    x.data[x.tail] = item
    x.tail = next
  fence()
  x.counter.signal()

proc len*[T](x: var MpscQueue[T]): Natural {.inline.} = 
  x.len
  
proc sync*[T](x: var MpscQueue[T]) {.inline.} = 
  x.len.inc(x.counter.wait())
  
proc take*[T](x: var MpscQueue[T]): T = 
  result = move(x.data[x.head])
  x.head = (x.head + 1) and x.mask
  x.len.dec()

when isMainModule and defined(linux):
  import std/os
  import std/posix

  proc eventfd*(initval: cuint, flags: cint): cint {.
    importc: "eventfd", 
    header: "<sys/eventfd.h>"
  .}

  type 
    MySigCounter = ptr object of SigCounter
      efd: cint

  proc signalMySigCounter(c: SigCounter) = 
    var buf = 1'u64
    if cast[MySigCounter](c).efd.write(buf.addr, sizeof(buf)) < 0:
      raiseOSError(osLastError())
  
  proc waitMySigCounter(c: SigCounter): Natural = 
    var buf = 0'u64
    if cast[MySigCounter](c).efd.read(buf.addr, sizeof(buf)) < 0:
      raiseOSError(osLastError())
    result = buf # TODO: u64 -> int 考虑溢出
    echo "wait:", $buf

  proc allocMySigCounter(): SigCounter = 
    let p = cast[MySigCounter](allocShared0(sizeof(MySigCounter)))
    p.signalImpl = signalMySigCounter
    p.waitImpl = waitMySigCounter
    p.efd = eventfd(0, 0)
    if p.efd < 0:
      raiseOSError(osLastError())
    result = p

  proc deallocMySigCounter(c: SigCounter) =
    deallocShared(cast[MySigCounter](c))

  var rcounter = 0
  var rsum = 0
  var mq = initMpscQueue[int](initAlloctor(allocMySigCounter, deallocMySigCounter))

  proc producerFunc() {.thread.} =
    for i in 1..1000:
      mq.add(i) 

  proc consumerFunc() {.thread.} =
    while rcounter < 4000:
      mq.sync()
      while mq.len > 0:
        rcounter.inc()
        var val = mq.take()
        rsum.inc(val)

  proc test() = 
    var producers: array[4, Thread[void]]
    var comsumer: Thread[void]
    for i in 0..<4:
      createThread(producers[i], producerFunc)
    createThread(comsumer, consumerFunc)
    joinThreads(producers)
    joinThreads(comsumer)
    doAssert rsum == ((1 + 1000) * (1000 div 2)) * 4 # (1 + n) * n / 2

  test()


import std/[asyncdispatch]
import deques

import ./exports/fututils

type
    Lock* = ref object of RootRef
    ## Keep order

    LockImpl = ref object of Lock
        queue: Deque[Future[void]]

    LockList = ref object of Lock
        ## High chance of deadlocks if you mess up
        locks: seq[Lock]
        locked: bool

## Lock methods

proc new*(T: type Lock): LockImpl
proc acquire*(self: Lock, cancelFut: Future[void]): Future[bool]
method acquire*(self: Lock): Future[void] {.base.} = discard
method release*(self: Lock) {.gcsafe base.} = discard
method isLocked*(self: Lock): bool {.base.} = discard

proc new*(T: type LockImpl): T
method acquire*(self: LockImpl): Future[void]
method release*(self: LockImpl) {.gcsafe.}
method isLocked*(self: LockImpl): bool


template withLock*(self: Lock, body: untyped): untyped =
    ## Be careful of issue #14714 that doesn't allow mixin waitFor and await on try/except
    await self.acquire()
    for i in 0 .. 0:
        defer: self.release()
        # Most hygienic way to allow break
        body

template withLock*(self: Lock, cancelFut: Future[void], body: untyped): untyped =
    let hasLocked = await self.acquire(cancelFut)
    if hasLocked:
        for i in 0 .. 0:
            defer: self.release()
            body


proc new*(T: type Lock): LockImpl =
    # LockImpl can't be base class, so must be a fake child
    LockImpl.new()

proc acquire*(self: Lock, cancelFut: Future[void]): Future[bool] {.async.} =
    ## If cancelFut completes first: 
    ##      - lock won't be acquired
    ##      - false will be returned
    ## Useful for timeouts using sleepAsync
    let acquireFut = self.acquire()
    result = await checkWithCancel(acquireFut, cancelFut)
    if not result:
        acquireFut.addCallback(proc() =
            self.release()
        )

proc new*(T: type LockImpl): T =
    T()

method acquire*(self: LockImpl): Future[void] {.async.} =
    result = newFuture[void]("Lock")
    self.queue.addLast(result)
    if self.queue.len() >= 2:
        await self.queue[^2] # previous

method release*(self: LockImpl) =
    var f = self.queue.popFirst()
    f.complete()

method isLocked*(self: LockImpl): bool =
    self.queue.len() > 0


## LockList methods

proc merge*(locks: varargs[Lock]): LockList
proc `and`*(a, b: Lock): LockList
method acquire*(self: LockList): Future[void]
method release*(self: LockList) {.gcsafe.}
method isLocked*(self: LockList): bool


proc merge*(locks: varargs[Lock]): LockList =
    LockList(locks: @locks)


proc `and`*(a, b: Lock): LockList =
    merge(a, b)

method acquire*(self: LockList): Future[void] =
    self.locked = true
    var allFuts = newSeqOfCap[Future[void]](self.locks.len())
    for l in self.locks:
        allFuts.add(l.acquire())
    result = all(allFuts)

method release*(self: LockList) {.gcsafe.} =
    for l in self.locks:
        l.release()
    self.locked = false

method isLocked*(self: LockList): bool =
    self.locked
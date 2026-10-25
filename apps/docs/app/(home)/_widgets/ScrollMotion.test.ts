import { expect, mock, test } from "bun:test";
import { startScrollMotion } from "./ScrollMotion";

test("scroll entrances run on entry, honor reduced motion, and clean up", () => {
  const animation = { cancel: mock(() => {}), onfinish: null };
  const target = { animate: mock(() => animation), matches: () => false };
  let notify: IntersectionObserverCallback = () => {};
  let observerOptions: IntersectionObserverInit | undefined;
  let preferenceChanged = () => {};
  const media = {
    matches: false,
    addEventListener: mock((_event: string, callback: () => void) => { preferenceChanged = callback; }),
    removeEventListener: mock(() => {}),
  };
  const observe = mock(() => {});
  const unobserve = mock(() => {});
  const disconnect = mock(() => {});
  class Observer {
    constructor(callback: IntersectionObserverCallback, options?: IntersectionObserverInit) {
      notify = callback;
      observerOptions = options;
    }
    observe = observe;
    unobserve = unobserve;
    disconnect = disconnect;
  }
  const globals = {
    window: { matchMedia: () => media },
    document: { querySelectorAll: () => [target] },
    IntersectionObserver: Observer,
  };
  const descriptors = Object.fromEntries(Object.keys(globals).map((key) => [key, Object.getOwnPropertyDescriptor(globalThis, key)]));
  try {
    for (const [key, value] of Object.entries(globals)) Object.defineProperty(globalThis, key, { configurable: true, value });
    const cleanup = startScrollMotion();
    expect(observerOptions).toEqual({ threshold: 0, rootMargin: "0px" });
    expect(observe).toHaveBeenCalledTimes(1);
    notify([{ isIntersecting: false, target } as unknown as IntersectionObserverEntry], {} as IntersectionObserver);
    expect(target.animate).not.toHaveBeenCalled();
    notify([{ isIntersecting: true, target } as unknown as IntersectionObserverEntry], {} as IntersectionObserver);
    expect(target.animate).toHaveBeenCalledWith(
      [{ transform: "translateY(6px)" }, { transform: "translateY(0)" }],
      { duration: 280, easing: "ease" },
    );
    expect(unobserve).not.toHaveBeenCalled();
    notify([{ isIntersecting: false, target } as unknown as IntersectionObserverEntry], {} as IntersectionObserver);
    expect(animation.cancel).toHaveBeenCalledTimes(1);
    notify([{ isIntersecting: true, target } as unknown as IntersectionObserverEntry], {} as IntersectionObserver);
    expect(target.animate).toHaveBeenCalledTimes(2);
    media.matches = true;
    preferenceChanged();
    expect(animation.cancel).toHaveBeenCalledTimes(2);
    expect(observe).toHaveBeenCalledTimes(1);
    cleanup();
    expect(disconnect).toHaveBeenCalledTimes(3);
    expect(media.removeEventListener).toHaveBeenCalledTimes(1);
    const reducedCleanup = startScrollMotion();
    expect(observe).toHaveBeenCalledTimes(1);
    reducedCleanup();
  } finally {
    for (const [key, descriptor] of Object.entries(descriptors)) {
      if (descriptor) Object.defineProperty(globalThis, key, descriptor);
      else Reflect.deleteProperty(globalThis, key);
    }
  }
});

declare module 'phoenix' {
  export class Socket {
    constructor(endPoint: string, opts?: Record<string, unknown>)
    connect(): void
    disconnect(): void
    channel(topic: string, params?: Record<string, unknown>): Channel
  }

  export class Channel {
    join(): Push
    leave(): Push
    on(event: string, callback: (payload: any) => void): void
    push(event: string, payload?: Record<string, unknown>): Push
  }

  export class Push {
    receive(status: string, callback: (response: any) => void): Push
  }
}

#import "FlutterRTCDataChannel.h"
#import <WebRTC/RTCDataChannelConfiguration.h>
#import <objc/runtime.h>
#import "FlutterRTCPeerConnection.h"

@implementation RTCDataChannel (Flutter)

- (NSString*)peerConnectionId {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setPeerConnectionId:(NSString*)peerConnectionId {
  objc_setAssociatedObject(self, @selector(peerConnectionId), peerConnectionId,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (FlutterEventSink)eventSink {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setEventSink:(FlutterEventSink)eventSink {
  objc_setAssociatedObject(self, @selector(eventSink), eventSink,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSArray<id>*)eventQueue {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setEventQueue:(NSArray<id>*)eventQueue {
  objc_setAssociatedObject(self, @selector(eventQueue), eventQueue,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (NSNumber*)flutterChannelId {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setFlutterChannelId:(NSNumber*)flutterChannelId {
  objc_setAssociatedObject(self, @selector(flutterChannelId), flutterChannelId,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (FlutterEventChannel*)eventChannel {
  return objc_getAssociatedObject(self, _cmd);
}

- (void)setEventChannel:(FlutterEventChannel*)eventChannel {
  objc_setAssociatedObject(self, @selector(eventChannel), eventChannel,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

#pragma mark - FlutterStreamHandler methods

- (FlutterError* _Nullable)onCancelWithArguments:(id _Nullable)arguments {
  self.eventSink = nil;
  return nil;
}

- (FlutterError* _Nullable)onListenWithArguments:(id _Nullable)arguments
                                       eventSink:(nonnull FlutterEventSink)sink {
  self.eventSink = sink;
  NSEnumerator* enumerator = [self.eventQueue objectEnumerator];
  id event;
  while ((event = enumerator.nextObject) != nil) {
    postEvent(sink, event);
  };
  self.eventQueue = nil;
  return nil;
}
@end

@implementation FlutterWebRTCPlugin (RTCDataChannel)

- (void)createDataChannel:(nonnull NSString*)peerConnectionId
                    label:(NSString*)label
                   config:(RTCDataChannelConfiguration*)config
                messenger:(NSObject<FlutterBinaryMessenger>*)messenger
                   result:(nonnull FlutterResult)result {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = [peerConnection dataChannelForLabel:label configuration:config];

  if (nil != dataChannel) {
    dataChannel.peerConnectionId = peerConnectionId;
    NSString* flutterId = [[NSUUID UUID] UUIDString];
    peerConnection.dataChannels[flutterId] = dataChannel;
    dataChannel.flutterChannelId = flutterId;
    // OOJACK PATCH: clear the queue BEFORE attaching the delegate, not after.
    // Upstream set `delegate = self` first and then wiped `eventQueue`, which
    // discards any state-change event the delegate delivers synchronously on
    // registration.
    dataChannel.eventQueue = nil;
    dataChannel.delegate = self;

    FlutterEventChannel* eventChannel = [FlutterEventChannel
        eventChannelWithName:[NSString stringWithFormat:@"FlutterWebRTC/dataChannelEvent%1$@%2$@",
                                                        peerConnectionId, flutterId]
             binaryMessenger:messenger];

    dataChannel.eventChannel = eventChannel;
    [eventChannel setStreamHandler:dataChannel];

    // OOJACK PATCH: report the channel's CURRENT readyState back to Dart.
    //
    // Upstream returns only label/id/flutterId, so the Dart RTCDataChannel is
    // constructed with `_state == null` and can ONLY learn its state from a
    // later `dataChannelDidChangeState:` delegate callback. libwebrtc's
    // DataChannelInterface::RegisterObserver() does NOT replay the state the
    // channel is already in, so any transition that happened at or before
    // creation is lost forever.
    //
    // That is exactly the case for a `negotiated: true` channel created on an
    // SCTP transport that is ALREADY connected: libwebrtc's SctpDataChannel
    // has handshake_state == kHandshakeReady and connected_to_transport ==
    // true at construction, so it goes straight to kOpen inside
    // dataChannelForLabel:configuration: — there is no kConnecting -> kOpen
    // transition left to observe. The first data channel on a transport works
    // (SCTP is still connecting when it is created, so it does transition
    // later, with the delegate attached); every subsequent one is born open
    // and the Dart side hangs at readyState == null forever.
    //
    // Sampling readyState here — AFTER the delegate is attached — closes the
    // gap from both sides: a transition before this point is caught by the
    // sample, one after it is caught by the delegate.
    NSString* initialState = [self stringForDataChannelState:dataChannel.readyState];
    NSLog(@"[FlutterRTCDataChannel] createDataChannel label=%@ sctpId=%d initialReadyState=%@",
          label, dataChannel.channelId, initialState);

    result(@{
      @"label" : label,
      @"id" : [NSNumber numberWithInt:dataChannel.channelId],
      @"flutterId" : flutterId,
      @"state" : (initialState ?: (id)[NSNull null])
    });
  }
}

- (void)dataChannelClose:(nonnull NSString*)peerConnectionId
           dataChannelId:(nonnull NSString*)dataChannelId {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  NSMutableDictionary* dataChannels = peerConnection.dataChannels;
  RTCDataChannel* dataChannel = dataChannels[dataChannelId];
  if (dataChannel) {
    FlutterEventChannel* eventChannel = dataChannel.eventChannel;
    [dataChannel close];
    [dataChannels removeObjectForKey:dataChannelId];
    [eventChannel setStreamHandler:nil];
    dataChannel.eventChannel = nil;
  }
}

- (void)dataChannelGetBufferedAmount:(nonnull NSString*)peerConnectionId
          dataChannelId:(nonnull NSString*)dataChannelId 
                result:(nonnull FlutterResult)result {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = peerConnection.dataChannels[dataChannelId];
  if(dataChannel == NULL || dataChannel.readyState != RTCDataChannelStateOpen) {
    result([FlutterError
          errorWithCode:[NSString stringWithFormat:@"%@Failed", @"dataChannelGetBufferedAmount"]
                message:[NSString stringWithFormat:@"Error: dataChannel not found or not opened!"]
                details:nil]);
  } else {
    result(@{@"bufferedAmount": @(dataChannel.bufferedAmount)});
  }
}

- (void)dataChannelSend:(nonnull NSString*)peerConnectionId
          dataChannelId:(nonnull NSString*)dataChannelId
                   data:(id)data
                   type:(NSString*)type {
  RTCPeerConnection* peerConnection = self.peerConnections[peerConnectionId];
  RTCDataChannel* dataChannel = peerConnection.dataChannels[dataChannelId];

  NSData* bytes = [type isEqualToString:@"binary"] ? ((FlutterStandardTypedData*)data).data
                                                   : [data dataUsingEncoding:NSUTF8StringEncoding];

  RTCDataBuffer* buffer = [[RTCDataBuffer alloc] initWithData:bytes
                                                     isBinary:[type isEqualToString:@"binary"]];
  [dataChannel sendData:buffer];
}

- (NSString*)stringForDataChannelState:(RTCDataChannelState)state {
  switch (state) {
    case RTCDataChannelStateConnecting:
      return @"connecting";
    case RTCDataChannelStateOpen:
      return @"open";
    case RTCDataChannelStateClosing:
      return @"closing";
    case RTCDataChannelStateClosed:
      return @"closed";
  }
  return nil;
}

- (void)sendEvent:(id)event withChannel:(RTCDataChannel*)channel {
  if (channel.eventSink) {
    postEvent(channel.eventSink, event);
  } else {
    if (!channel.eventQueue) {
      channel.eventQueue = [NSMutableArray array];
    }
    channel.eventQueue = [channel.eventQueue arrayByAddingObject:event];
  }
}

#pragma mark - RTCDataChannelDelegate methods

// Called when the data channel state has changed.
- (void)dataChannelDidChangeState:(RTCDataChannel*)channel {
  [self sendEvent:@{
    @"event" : @"dataChannelStateChanged",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"state" : [self stringForDataChannelState:channel.readyState]
  }
      withChannel:channel];
}

// Called when a data buffer was successfully received.
- (void)dataChannel:(RTCDataChannel*)channel didReceiveMessageWithBuffer:(RTCDataBuffer*)buffer {
  NSString* type;
  id data;
  if (buffer.isBinary) {
    type = @"binary";
    data = [FlutterStandardTypedData typedDataWithBytes:buffer.data];
  } else {
    type = @"text";
    data = [[NSString alloc] initWithData:buffer.data encoding:NSUTF8StringEncoding];
  }

  [self sendEvent:@{
    @"event" : @"dataChannelReceiveMessage",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"type" : type,
    @"data" : (data ? data : [NSNull null])
  }
      withChannel:channel];
}

- (void)dataChannel:(RTCDataChannel*)channel didChangeBufferedAmount:(uint64_t)amount {
  [self sendEvent:@{
    @"event" : @"dataChannelBufferedAmountChange",
    @"id" : [NSNumber numberWithInt:channel.channelId],
    @"bufferedAmount" : [NSNumber numberWithLongLong:channel.bufferedAmount],
    @"changedAmount" : [NSNumber numberWithLongLong:amount]
  }
      withChannel:channel];
}

@end

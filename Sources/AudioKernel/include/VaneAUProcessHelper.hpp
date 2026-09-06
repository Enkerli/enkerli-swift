//
//  VaneAUProcessHelper.hpp
//  AudioKernel
//
//  The event-splitting render loop, for a kernel that writes samples.
//
//  Deliberately a separate file from `PluginAUProcessHelper.hpp` rather than a
//  template over both. The loops look nearly identical and differ in the one
//  thing that matters: the MIDI helper never touches `outputData`, because a
//  MIDI processor produces no audio and writing to that buffer would be a bug.
//  This one must fill it completely — every sample of every segment, including
//  the segments where nothing is sounding.
//
//  Templating them would have saved about twenty lines and made the reader of
//  either one prove to themselves which branch applied. The duplication is the
//  cheaper of the two.
//
//  The other difference is subtle and is the reason `process` takes a start
//  frame: an event splits the block into segments, and each segment must write
//  to its *own offset* in the output buffer. The MIDI helper can pass `now` and
//  a count because it has nowhere to write; here, forgetting the offset produces
//  a block whose first segment is written repeatedly over itself — which sounds
//  like a stutter at the block rate and looks, in a waveform view, almost right.
//

#pragma once

#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#include "VaneDSPKernel.hpp"

class VaneAUProcessHelper {
public:
    VaneAUProcessHelper(VaneDSPKernel &kernel) : mKernel{kernel} {}

    void processWithEvents(AudioBufferList *output, AudioTimeStamp const *timestamp,
                           AUAudioFrameCount frameCount, AURenderEvent const *events) {
        AUEventSampleTime now = AUEventSampleTime(timestamp->mSampleTime);
        AUAudioFrameCount framesRemaining = frameCount;
        AURenderEvent const *nextEvent = events;
        AUAudioFrameCount writeOffset = 0;

        while (framesRemaining > 0) {
            if (nextEvent == nullptr) {
                mKernel.process(output, writeOffset, framesRemaining);
                return;
            }

            const auto headEventTime = nextEvent->head.eventSampleTime;
            AUAudioFrameCount framesThisSegment =
                AUAudioFrameCount(std::max(AUEventSampleTime(0), headEventTime - now));
            framesThisSegment = std::min(framesThisSegment, framesRemaining);

            if (framesThisSegment > 0) {
                mKernel.process(output, writeOffset, framesThisSegment);
                framesRemaining -= framesThisSegment;
                writeOffset += framesThisSegment;
                now += AUEventSampleTime(framesThisSegment);
            }

            nextEvent = performAllSimultaneousEvents(now, nextEvent);
        }
    }

    AURenderEvent const *performAllSimultaneousEvents(AUEventSampleTime now,
                                                      AURenderEvent const *event) {
        do {
            mKernel.handleOneEvent(now, event);
            event = event->head.next;
        } while (event && event->head.eventSampleTime <= now);
        return event;
    }

    AUInternalRenderBlock internalRenderBlock() {
        return ^AUAudioUnitStatus(AudioUnitRenderActionFlags *actionFlags,
                                  const AudioTimeStamp *timestamp,
                                  AUAudioFrameCount frameCount,
                                  NSInteger outputBusNumber,
                                  AudioBufferList *outputData,
                                  const AURenderEvent *events,
                                  AURenderPullInputBlock __unsafe_unretained pullInputBlock) {
            if (frameCount > mKernel.maximumFramesToRender()) {
                return kAudioUnitErr_TooManyFramesToProcess;
            }
            // A host may hand over null buffer pointers and expect the audio
            // unit to supply its own memory. An instrument that cannot do that
            // must at least not write through the null — silence from a missing
            // buffer is a bad note; a crash is a dead session.
            for (UInt32 channel = 0; channel < outputData->mNumberBuffers; ++channel) {
                if (outputData->mBuffers[channel].mData == nullptr) {
                    return kAudioUnitErr_InvalidParameter;
                }
            }
            processWithEvents(outputData, timestamp, frameCount, events);
            return noErr;
        };
    }

private:
    VaneDSPKernel &mKernel;
};

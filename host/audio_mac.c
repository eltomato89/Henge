/* The guest's sound on the host (Mac or iOS): the default output device through an AudioUnit
   whose render callback pulls PCM straight from the virtio-snd ring. The unit
   is set to the stream's own format, and CoreAudio converts to the device. */
#include "audio_mac.h"

#include <AudioToolbox/AudioToolbox.h>
#include <TargetConditionals.h>

/* The Mac's default output device, or the iOS app's own output (the app sets its audio session to playback). */
#include <stdint.h>
#if TARGET_OS_IPHONE
#define HV_OUTPUT_UNIT kAudioUnitSubType_RemoteIO
#else
#define HV_OUTPUT_UNIT kAudioUnitSubType_DefaultOutput
#endif
#include <stdio.h>

static AudioComponentInstance unit;
static int unit_running;
static unsigned cur_channels, cur_format, cur_rate;

#if TARGET_OS_IPHONE
/* The microphone: a second RemoteIO unit with only its input bus on, set to the guest's capture
   format, so the unit converts from the hardware's. The app puts its audio session in
   play-and-record and asks for permission first (Microphone.swift); without them this fails or
   records silence, and either way the guest's capture stream keeps running. */
static AudioComponentInstance in_unit;
static unsigned in_frame_bytes, in_channels;
static uint8_t in_buf[1 << 16];

static OSStatus capture(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                        UInt32 frames, AudioBufferList *io) {
    (void)io;
    HvVirtioSnd *d = ref;
    UInt32 bytes = frames * in_frame_bytes;
    if (!in_unit || !bytes || bytes > sizeof in_buf) return noErr;
    AudioBufferList bl;
    bl.mNumberBuffers = 1;
    bl.mBuffers[0].mNumberChannels = in_channels;
    bl.mBuffers[0].mDataByteSize = bytes;
    bl.mBuffers[0].mData = in_buf;
    if (AudioUnitRender(in_unit, flags, ts, bus, frames, &bl) == noErr)
        hv_virtio_snd_push(d, in_buf, bl.mBuffers[0].mDataByteSize);
    return noErr;
}

static void in_stop(void *opaque) {
    (void)opaque;
    if (!in_unit) return;
    AudioOutputUnitStop(in_unit); /* waits for the capture callback to finish */
    AudioUnitUninitialize(in_unit);
    AudioComponentInstanceDispose(in_unit);
    in_unit = NULL;
}

static int in_start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    in_stop(opaque);
    AudioComponentDescription desc = {kAudioUnitType_Output, kAudioUnitSubType_RemoteIO, kAudioUnitManufacturer_Apple, 0, 0};
    AudioComponent comp = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstance u = NULL;
    if (!comp || AudioComponentInstanceNew(comp, &u) != noErr) return -1;
    unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate_hz;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                     kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
    f.mFramesPerPacket = 1;
    f.mChannelsPerFrame = channels;
    f.mBitsPerChannel = bytes * 8;
    UInt32 on = 1, off = 0;
    AURenderCallbackStruct cb = {capture, d};
    OSStatus st;
    /* Bus 1 is the microphone, bus 0 the speaker: this unit records only (the output unit above plays). */
    if ((st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &on, sizeof on)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &off, sizeof off)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &f, sizeof f)) != noErr ||
        (st = AudioUnitSetProperty(u, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 0, &cb, sizeof cb)) != noErr ||
        (st = AudioUnitInitialize(u)) != noErr) {
        fprintf(stderr, "hengevm: sound: the microphone refused %u ch, format %u, %u Hz (status %d)\n", channels, format, rate_hz, (int)st);
        AudioComponentInstanceDispose(u);
        return -1;
    }
    in_frame_bytes = bytes * channels;
    in_channels = channels;
    in_unit = u;
    if ((st = AudioOutputUnitStart(u)) != noErr) {
        fprintf(stderr, "hengevm: sound: the microphone did not start (status %d)\n", (int)st);
        in_stop(opaque);
        return -1;
    }
    return 0;
}
#endif

static OSStatus render(void *ref, AudioUnitRenderActionFlags *flags, const AudioTimeStamp *ts, UInt32 bus,
                       UInt32 frames, AudioBufferList *io) {
    (void)flags, (void)ts, (void)bus, (void)frames;
    HvVirtioSnd *d = ref;
    for (UInt32 i = 0; i < io->mNumberBuffers; i++)
        hv_virtio_snd_pull(d, io->mBuffers[i].mData, io->mBuffers[i].mDataByteSize);
    return noErr;
}

static int start(void *opaque, unsigned channels, unsigned format, unsigned rate_hz) {
    HvVirtioSnd *d = opaque;
    if (unit && (channels != cur_channels || format != cur_format || rate_hz != cur_rate)) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
        unit_running = 0;
    }
    if (!unit) {
        AudioComponentDescription desc = {kAudioUnitType_Output, HV_OUTPUT_UNIT,
                                          kAudioUnitManufacturer_Apple, 0, 0};
        AudioComponent comp = AudioComponentFindNext(NULL, &desc);
        if (!comp || AudioComponentInstanceNew(comp, &unit) != noErr) return -1;
        unsigned bytes = format == HV_VSND_FMT_S16 ? 2 : 4;
        AudioStreamBasicDescription f = {0};
        f.mSampleRate = rate_hz;
        f.mFormatID = kAudioFormatLinearPCM;
        f.mFormatFlags = (format == HV_VSND_FMT_FLOAT ? kAudioFormatFlagIsFloat : kAudioFormatFlagIsSignedInteger) |
                         kAudioFormatFlagIsPacked;
        f.mBytesPerPacket = f.mBytesPerFrame = bytes * channels;
        f.mFramesPerPacket = 1;
        f.mChannelsPerFrame = channels;
        f.mBitsPerChannel = bytes * 8;
        AURenderCallbackStruct cb = {render, d};
        if (AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &f, sizeof f) != noErr ||
            AudioUnitSetProperty(unit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &cb, sizeof cb) != noErr ||
            AudioUnitInitialize(unit) != noErr) {
            fprintf(stderr, "hengevm: sound: the output device refused %u ch, format %u, %u Hz\n", channels, format, rate_hz);
            AudioComponentInstanceDispose(unit);
            unit = NULL;
            return -1;
        }
        cur_channels = channels, cur_format = format, cur_rate = rate_hz;
    }
    if (!unit_running && AudioOutputUnitStart(unit) == noErr) unit_running = 1;
    return unit_running ? 0 : -1;
}

static void stop(void *opaque) {
    (void)opaque;
    if (unit && unit_running) AudioOutputUnitStop(unit); /* waits for the render callback to finish */
    unit_running = 0;
}

void hv_audio_attach(HvVirtioSnd *d) {
    d->backend = (HvVirtioSndBackend){start, stop, d};
#if TARGET_OS_IPHONE
    d->backend.in_start = in_start;
    d->backend.in_stop = in_stop;
#endif
}

void hv_audio_detach(void) {
#if TARGET_OS_IPHONE
    in_stop(NULL);
#endif
    if (unit) {
        AudioOutputUnitStop(unit);
        AudioUnitUninitialize(unit);
        AudioComponentInstanceDispose(unit);
        unit = NULL;
    }
    unit_running = 0;
    cur_channels = cur_format = cur_rate = 0;
}

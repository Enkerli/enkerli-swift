//
//  sysex-main.mm
//  Kernel
//
//  The fourth job: carrying opaque bytes without touching them.
//
//  The other three harnesses check things with a musical symptom. A wrong note
//  is audible; a stuck note is audible for a long time. This one checks a
//  contract with **no musical symptom at all** — "the bytes that went in are the
//  bytes that came out" — and when it breaks, what a user sees is a device that
//  does not answer. There is nothing to hear and nothing to look at. So this is
//  the capability most in need of a harness and the one where a green is worth
//  the least if the harness is not adversarial.
//
//  Two things make it easy to get wrong and both are checked here:
//
//  · **UMP does not carry F0 and F7.** SysEx7 replaced that framing with a
//    status nibble. Sending them as data bytes produces a frame no device
//    accepts and a byte dump that looks right.
//  · **A frame spans packets.** Six data bytes per packet, maximum. A frame of
//    seven bytes is two packets, and getting the start/continue/end statuses
//    wrong shows up only on frames longer than six — which the RND's own
//    eleven-byte seed message is, and a hand-written test of a short frame is
//    not.
//
//  Compiled and run by Scripts/check-kernel.sh.
//

#import <Foundation/Foundation.h>
#import "../../Sources/Kernel/include/PluginDSPKernel.hpp"

#import <string>
#import <vector>

// ── A recording output block that reassembles SysEx7 ───────────────────────
//
// Deliberately written from the UMP spec rather than by calling the kernel's own
// reassembler: a test that decoded with the same code it encoded with would pass
// on any self-consistent scheme, including a wrong one.

static std::vector<std::vector<uint8_t>> gFrames;
static std::vector<uint32_t> gStatuses;
static int gNonSysExWords = 0;

static void resetSent() { gFrames.clear(); gStatuses.clear(); gNonSysExWords = 0; }

static AUMIDIEventListBlock recordingBlock() {
    return ^(AUEventSampleTime, uint8_t, const MIDIEventList *list) {
        if (list == nullptr) { return (OSStatus)noErr; }
        static std::vector<uint8_t> partial;
        const MIDIEventPacket *packet = &list->packet[0];
        for (uint32_t p = 0; p < list->numPackets; ++p) {
            for (uint32_t w = 0; w < packet->wordCount; ++w) {
                const uint32_t first = packet->words[w];
                const uint8_t type = (uint8_t)((first >> 28) & 0xF);
                if (type != 0x3) { gNonSysExWords += 1; continue; }
                if (w + 1 >= packet->wordCount) { break; }
                const uint32_t second = packet->words[w + 1];
                const uint8_t status = (uint8_t)((first >> 20) & 0xF);
                const uint8_t count = (uint8_t)((first >> 16) & 0xF);
                gStatuses.push_back(status);

                if (status == 0x0 || status == 0x1) { partial.clear(); }
                const uint8_t data[6] = {
                    (uint8_t)((first >> 8) & 0x7F), (uint8_t)(first & 0x7F),
                    (uint8_t)((second >> 24) & 0x7F), (uint8_t)((second >> 16) & 0x7F),
                    (uint8_t)((second >> 8) & 0x7F), (uint8_t)(second & 0x7F)
                };
                for (uint8_t b = 0; b < count && b < 6; ++b) { partial.push_back(data[b]); }
                if (status == 0x0 || status == 0x3) { gFrames.push_back(partial); partial.clear(); }
                w += 1;
            }
            packet = MIDIEventPacketNext(packet);
        }
        return (OSStatus)noErr;
    };
}

// ── Feeding it ─────────────────────────────────────────────────────────────

/// Delivers a frame the way a host does: SysEx7 packets, no F0, no F7.
static void feedSysEx(PluginDSPKernel &kernel, const std::vector<uint8_t> &payload) {
    MIDIEventList list = {};
    MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_2_0);

    size_t sent = 0;
    do {
        const size_t chunk = (payload.size() - sent) > 6 ? 6 : (payload.size() - sent);
        const bool isFirst = sent == 0;
        const bool isLast = sent + chunk >= payload.size();
        const uint8_t status = isFirst ? (isLast ? 0x0 : 0x1) : (isLast ? 0x3 : 0x2);
        uint8_t bytes[6] = {};
        for (size_t i = 0; i < chunk; ++i) { bytes[i] = payload[sent + i]; }
        const uint32_t words[2] = {
            ((uint32_t)0x3 << 28) | ((uint32_t)status << 20) | ((uint32_t)chunk << 16)
                | ((uint32_t)bytes[0] << 8) | (uint32_t)bytes[1],
            ((uint32_t)bytes[2] << 24) | ((uint32_t)bytes[3] << 16)
                | ((uint32_t)bytes[4] << 8) | (uint32_t)bytes[5]
        };
        packet = MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 2, words);
        sent += chunk;
    } while (sent < payload.size());

    // AURenderEvent is a union — the event type goes inside the payload. See
    // the long note in transform-main.mm; this harness inherited the fix rather
    // than rediscovering it.
    AUMIDIEventList wrapper = {};
    wrapper.eventType = AURenderEventMIDIEventList;
    wrapper.eventList = list;
    AURenderEvent event = {};
    event.MIDIEventsList = wrapper;
    kernel.handleOneEvent(0, &event);
}

static uint32_t noteWord(uint8_t status, uint8_t channel, uint8_t note, uint8_t velocity) {
    return ((uint32_t)0x2 << 28) | ((uint32_t)(status & 0xF) << 20)
         | ((uint32_t)(channel & 0xF) << 16)
         | ((uint32_t)(note & 0x7F) << 8) | (uint32_t)(velocity & 0x7F);
}

static void feedWord(PluginDSPKernel &kernel, uint32_t word) {
    MIDIEventList list = {};
    MIDIEventPacket *packet = MIDIEventListInit(&list, kMIDIProtocol_2_0);
    packet = MIDIEventListAdd(&list, sizeof(MIDIEventList), packet, 0, 1, &word);
    AUMIDIEventList wrapper = {};
    wrapper.eventType = AURenderEventMIDIEventList;
    wrapper.eventList = list;
    AURenderEvent event = {};
    event.MIDIEventsList = wrapper;
    kernel.handleOneEvent(0, &event);
}

// ── Saying what happened ───────────────────────────────────────────────────

static int gFailures = 0;

static void check(const std::string &what, bool passed, const std::string &detail = "") {
    printf("  %s  %s%s\n", passed ? "PASS" : "FAIL", what.c_str(),
           detail.empty() ? "" : (" — " + detail).c_str());
    if (!passed) { gFailures += 1; }
}

static std::string hex(const std::vector<uint8_t> &bytes) {
    std::string out;
    char buffer[8];
    for (size_t i = 0; i < bytes.size(); ++i) {
        snprintf(buffer, sizeof(buffer), "%s%02X", i ? " " : "", bytes[i]);
        out += buffer;
    }
    return out;
}

/// The RND's seed message: F0 6F 62 78 10 <five septets> F7 — eleven bytes, so
/// nine of payload, so two SysEx7 packets. Chosen as the fixture precisely
/// because it is longer than one packet.
static std::vector<uint8_t> seedFrame(uint32_t seed) {
    std::vector<uint8_t> frame { 0xF0, 0x6F, 0x62, 0x78, 0x10 };
    for (int septet = 0; septet < 4; ++septet) {
        frame.push_back((uint8_t)((seed >> (7 * septet)) & 0x7F));
    }
    frame.push_back((uint8_t)((seed >> 28) & 0x0F));
    frame.push_back(0xF7);
    return frame;
}

static std::vector<uint8_t> framePayload(const std::vector<uint8_t> &frame) {
    return std::vector<uint8_t>(frame.begin() + 1, frame.end() - 1);
}

int main() {
    printf("── sysex: carrying bytes nobody may touch ─────────\n");

    // ── out: a burst is sent once ──────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();

        kernel.process(0, 512);
        check("nothing is sent until a burst is committed", gFrames.empty(),
              gFrames.empty() ? "" : std::to_string(gFrames.size()) + " frames");

        const auto frame = seedFrame(0xAA442CE7);
        kernel.beginSysExBurst();
        check("a frame is accepted", kernel.addSysExFrame(frame.data(), (uint32_t)frame.size()));
        kernel.commitSysExBurst();

        kernel.process(512, 512);
        check("and sent on the next block", gFrames.size() == 1,
              std::to_string(gFrames.size()) + " frames");
        if (gFrames.size() == 1) {
            check("byte for byte, F0 and F7 stripped as UMP requires",
                  gFrames[0] == framePayload(frame), hex(gFrames[0]));
            check("which is nine bytes, so two packets",
                  gStatuses.size() == 2 && gStatuses[0] == 0x1 && gStatuses[1] == 0x3,
                  std::to_string(gStatuses.size()) + " packets");
        }

        resetSent();
        kernel.process(1024, 512);
        check("a burst is sent once, not on every block", gFrames.empty(),
              gFrames.empty() ? "" : "sent again");

        // The property the probe's whole method rests on: a second burst with
        // different bytes is distinguishable from the first one's echo.
        resetSent();
        const auto second = seedFrame(0x5E5D0001);
        kernel.beginSysExBurst();
        kernel.addSysExFrame(second.data(), (uint32_t)second.size());
        kernel.commitSysExBurst();
        kernel.process(1536, 512);
        check("committing again sends the new burst", gFrames.size() == 1
              && gFrames[0] == framePayload(second),
              gFrames.empty() ? "nothing came out" : hex(gFrames[0]));
    }

    // ── out: a short frame is one packet ───────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        const std::vector<uint8_t> tiny { 0xF0, 0x7D, 0x01, 0xF7 };
        kernel.beginSysExBurst();
        kernel.addSysExFrame(tiny.data(), (uint32_t)tiny.size());
        kernel.commitSysExBurst();
        kernel.process(0, 512);
        check("a two-byte payload is one complete packet, not a start and an end",
              gStatuses.size() == 1 && gStatuses[0] == 0x0,
              std::to_string(gStatuses.size()) + " packets");
        check("and carries its two bytes", gFrames.size() == 1
              && gFrames[0] == std::vector<uint8_t>({ 0x7D, 0x01 }),
              gFrames.empty() ? "nothing" : hex(gFrames[0]));
    }

    // ── out: a burst of several frames ─────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        kernel.beginSysExBurst();
        const uint32_t seeds[4] = { 0x00000000, 0xFFFFFFFF, 0xAA442CE7, 0x0FEDCBA9 };
        for (uint32_t seed : seeds) {
            const auto frame = seedFrame(seed);
            kernel.addSysExFrame(frame.data(), (uint32_t)frame.size());
        }
        kernel.commitSysExBurst();
        kernel.process(0, 512);
        check("four frames go out as four frames", gFrames.size() == 4,
              std::to_string(gFrames.size()));
        if (gFrames.size() == 4) {
            check("in the order they were added",
                  gFrames[0] == framePayload(seedFrame(0x00000000))
                  && gFrames[3] == framePayload(seedFrame(0x0FEDCBA9)));
            // The all-ones seed is the one that catches a codec clamping to
            // 6 bits or sign-extending: every septet is 0x7F and the last is
            // 0x0F, the widest legal bytes in the encoding.
            check("and the widest legal bytes survive",
                  gFrames[1] == framePayload(seedFrame(0xFFFFFFFF)), hex(gFrames[1]));
        }

        check("a frame longer than a slot is refused rather than truncated",
              !kernel.addSysExFrame(seedFrame(0).data(), PluginDSPKernel::kSysExMaxBytes + 1));
    }

    // ── in: frames arrive whole ────────────────────────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();

        check("nothing has arrived yet", kernel.sysExInCount() == 0);

        const auto frame = seedFrame(0xAA442CE7);
        feedSysEx(kernel, framePayload(frame));
        check("one frame in, one frame counted", kernel.sysExInCount() == 1,
              std::to_string(kernel.sysExInCount()));

        std::vector<uint8_t> got;
        for (uint32_t i = 0; i < kernel.sysExInLength(0); ++i) {
            got.push_back(kernel.sysExInByte(0, i));
        }
        check("with F0 and F7 put back, because that is how the protocol is written",
              got == frame, hex(got));

        // The reason this matters: the probe reads the seed back out of these
        // bytes, and an off-by-one in the reassembly would decode to a
        // plausible wrong number rather than to an error.
        const uint32_t decoded = (uint32_t)got[5] | ((uint32_t)got[6] << 7)
                               | ((uint32_t)got[7] << 14) | ((uint32_t)got[8] << 21)
                               | ((uint32_t)got[9] << 28);
        char seedText[16];
        snprintf(seedText, sizeof(seedText), "0x%08X", decoded);
        check("and the seed decodes to what was sent", decoded == 0xAA442CE7, seedText);
    }

    // ── in: SysEx does not disturb the note path ───────────────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        resetSent();
        feedWord(kernel, noteWord(0x9, 0, 60, 100));
        check("a note is still forwarded while SysEx capture is on",
              gNonSysExWords >= 1, std::to_string(gNonSysExWords) + " non-SysEx words out");
        check("and is not mistaken for a SysEx frame", kernel.sysExInCount() == 0,
              std::to_string(kernel.sysExInCount()) + " frames");
    }

    // ── in: the ring drops the oldest rather than blocking ─────────────────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        const uint32_t overfill = PluginDSPKernel::kSysExInCapacity + 5;
        for (uint32_t i = 0; i < overfill; ++i) {
            feedSysEx(kernel, framePayload(seedFrame(i)));
        }
        check("every frame is counted even when the ring wrapped",
              kernel.sysExInCount() == overfill, std::to_string(kernel.sysExInCount()));
        check("and the oldest readable one has moved forward",
              kernel.oldestSysExIn() == overfill - PluginDSPKernel::kSysExInCapacity,
              std::to_string(kernel.oldestSysExIn()));
        const uint64_t newest = kernel.sysExInCount() - 1;
        const uint32_t decoded = (uint32_t)kernel.sysExInByte(newest, 5)
                               | ((uint32_t)kernel.sysExInByte(newest, 6) << 7)
                               | ((uint32_t)kernel.sysExInByte(newest, 7) << 14);
        check("the newest frame is the newest one sent, not a stale slot",
              decoded == overfill - 1, std::to_string(decoded));
    }

    // ── in: an over-long frame is reported, never silently shortened ───────
    {
        PluginDSPKernel kernel;
        kernel.initialize(48000);
        kernel.setMIDIOutputEventBlock(recordingBlock());
        std::vector<uint8_t> huge(PluginDSPKernel::kSysExMaxBytes + 20, 0x01);
        feedSysEx(kernel, huge);
        check("an over-long frame still arrives", kernel.sysExInCount() == 1);
        check("and is flagged as truncated rather than passed off as complete",
              kernel.sysExInTruncated() == 1, std::to_string(kernel.sysExInTruncated()));
    }

    printf("\n%s\n", gFailures == 0 ? "sysex: OK" : "sysex: FAILURES");
    return gFailures == 0 ? 0 : 1;
}

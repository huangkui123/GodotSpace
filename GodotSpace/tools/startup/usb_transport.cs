// USB transport for the Windows launcher. Compiled by Windows PowerShell;
// no Python, ffmpeg executable, admin service or installed scrcpy is needed.
using System;
using System.Collections.Generic;
using System.Collections.Concurrent;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;

namespace GodotSpace.Usb {
    public sealed class CameraRelay : IDisposable {
        readonly TcpListener listener;
        readonly string host;
        readonly int destinationPort;
        readonly ConcurrentDictionary<TcpClient, byte> sockets = new ConcurrentDictionary<TcpClient, byte>();
        volatile bool stopped;
        public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }

        public CameraRelay(string destination, int port) {
            host = destination;
            destinationPort = port;
            listener = new TcpListener(IPAddress.Loopback, 0);
            listener.Start(2);
            Task.Run((Action)Accept);
        }
        void Accept() {
            while (!stopped) {
                try {
                    var incoming = listener.AcceptTcpClient();
                    if (sockets.Count >= 4) { incoming.Close(); continue; }
                    sockets.TryAdd(incoming, 0);
                    Task.Run(() => Forward(incoming));
                } catch (SocketException) { if (stopped) return; }
                  catch (ObjectDisposedException) { return; }
            }
        }
        void Forward(TcpClient incoming) {
            var outgoing = new TcpClient();
            sockets.TryAdd(outgoing, 0);
            try {
                var connection = outgoing.ConnectAsync(host, destinationPort);
                if (!connection.Wait(3000)) return;
                incoming.NoDelay = outgoing.NoDelay = true;
                // PSA2 and its ACK travel unchanged; fixed-size CopyTo buffers
                // apply TCP backpressure without accumulating frames in RAM.
                var up = incoming.GetStream().CopyToAsync(outgoing.GetStream(), 32768);
                var down = outgoing.GetStream().CopyToAsync(incoming.GetStream(), 32768);
                Task.WaitAny(up, down);
            } catch (Exception) { /* helper reconnects when Server returns */ }
            finally {
                incoming.Close(); outgoing.Close();
                byte unused;
                sockets.TryRemove(incoming, out unused);
                sockets.TryRemove(outgoing, out unused);
            }
        }
        public void Dispose() {
            stopped = true; listener.Stop();
            foreach (var socket in sockets.Keys) socket.Close();
        }
    }

    public sealed class VideoFrame {
        public byte[] Data;
        public byte[] Config;
        public long Timestamp;
        public bool Key;
    }

    // Minimal single-program H.264 MPEG-TS muxer. Each viewer gets its own
    // zero-based PTS/PCR and continuity counters, starting on a keyframe.
    // No decoding/re-encoding happens on the SKY PC.
    public sealed class TransportStream {
        readonly int[] continuity = new int[8192];
        long origin = -1;
        int frames;
        static byte[] WithCrc(byte[] section) {
            uint crc = 0xffffffff;
            foreach (byte value in section) {
                crc ^= (uint)value << 24;
                for (int i = 0; i < 8; i++) crc = (crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7u : 0);
            }
            var result = new byte[section.Length + 5];
            Array.Copy(section, 0, result, 1, section.Length); // pointer_field = 0
            for (int i = 0; i < 4; i++) result[result.Length - 4 + i] = (byte)(crc >> (24 - i * 8));
            return result;
        }
        public byte[] Encode(VideoFrame frame) {
            if (origin < 0) origin = frame.Timestamp;
            long pts = Math.Max(0, frame.Timestamp - origin) * 9 / 100;
            using (var output = new MemoryStream()) {
                if (frame.Key || frames++ % 15 == 0) {
                    Packetize(output, 0, WithCrc(new byte[] {0,0xb0,13,0,1,0xc1,0,0,0,1,0xf0,0}), -1, false);
                    Packetize(output, 4096, WithCrc(new byte[] {2,0xb0,18,0,1,0xc1,0,0,0xe1,0,0xf0,0,0x1b,0xe1,0,0xf0,0}), -1, false);
                }
                using (var pes = new MemoryStream()) {
                    var header = new byte[] {0,0,1,0xe0,0,0,0x80,0x80,5,
                        (byte)(0x21 | ((pts >> 29) & 14)), (byte)(pts >> 22),
                        (byte)(1 | ((pts >> 14) & 254)), (byte)(pts >> 7), (byte)(1 | ((pts << 1) & 254)),
                        0,0,0,1,9,0xf0}; // H.264 access unit delimiter
                    pes.Write(header, 0, header.Length);
                    if (frame.Key && frame.Config != null) pes.Write(frame.Config, 0, frame.Config.Length);
                    pes.Write(frame.Data, 0, frame.Data.Length);
                    Packetize(output, 256, pes.ToArray(), pts, frame.Key);
                }
                return output.ToArray();
            }
        }
        void Packetize(Stream output, int pid, byte[] payload, long pcr, bool key) {
            int offset = 0;
            while (offset < payload.Length) {
                bool first = offset == 0;
                bool clock = first && pcr >= 0;
                int count = Math.Min(payload.Length - offset, clock ? 176 : 184);
                int adaptation = 184 - count;
                var packet = new byte[188];
                for (int i = 0; i < packet.Length; i++) packet[i] = 0xff;
                packet[0] = 0x47;
                packet[1] = (byte)((pid >> 8) | (first ? 0x40 : 0));
                packet[2] = (byte)pid;
                packet[3] = (byte)((adaptation > 0 ? 0x30 : 0x10) | (continuity[pid]++ & 15));
                if (adaptation > 0) {
                    packet[4] = (byte)(adaptation - 1);
                    if (adaptation > 1) packet[5] = (byte)((clock ? 0x10 : 0) | (first && key ? 0x40 : 0));
                    if (clock) {
                        packet[6] = (byte)(pcr >> 25); packet[7] = (byte)(pcr >> 17);
                        packet[8] = (byte)(pcr >> 9); packet[9] = (byte)(pcr >> 1);
                        packet[10] = (byte)(((pcr & 1) << 7) | 0x7e); packet[11] = 0;
                    }
                }
                Array.Copy(payload, offset, packet, 4 + adaptation, count);
                output.Write(packet, 0, packet.Length);
                offset += count;
            }
        }
    }

    public sealed class CastBridge : IDisposable {
        sealed class Viewer {
            public TcpClient Socket;
            public BlockingCollection<VideoFrame> Queue = new BlockingCollection<VideoFrame>(30);
            public bool Started;
            public long PendingBytes;
        }
        readonly TcpListener listener;
        readonly TcpClient source = new TcpClient();
        readonly ConcurrentDictionary<Viewer, byte> viewers = new ConcurrentDictionary<Viewer, byte>();
        readonly string path;
        readonly int sourcePort;
        volatile bool stopped;
        long lastFrameTicks;
        long frameCount;
        public string Error = "";
        public long FrameCount { get { return Interlocked.Read(ref frameCount); } }
        public bool IsLive { get { return DateTime.UtcNow.Ticks - Interlocked.Read(ref lastFrameTicks) < TimeSpan.FromSeconds(5).Ticks; } }
        public int Port { get { return ((IPEndPoint)listener.LocalEndpoint).Port; } }

        public CastBridge(int adbForwardPort, string accessToken, bool allowLan) {
            if (accessToken.Length != 48 || !System.Text.RegularExpressions.Regex.IsMatch(accessToken, "^[a-f0-9]+$"))
                throw new ArgumentException("Invalid cast token");
            sourcePort = adbForwardPort;
            path = "/" + accessToken + "/video.ts";
            listener = new TcpListener(allowLan ? IPAddress.Any : IPAddress.Loopback, 0);
            listener.Start(8);
            Task.Run((Action)Accept);
            Task.Run((Action)ReadVideo);
        }
        static byte[] ReadExact(Stream stream, int size) {
            var buffer = new byte[size];
            int offset = 0;
            while (offset < size) {
                int count = stream.Read(buffer, offset, size - offset);
                if (count == 0) throw new EndOfStreamException("USB video disconnected");
                offset += count;
            }
            return buffer;
        }
        public static ulong BigEndian(byte[] data, int offset, int length) {
            ulong value = 0;
            for (int i = 0; i < length; i++) value = (value << 8) | data[offset + i];
            return value;
        }
        void ReadVideo() {
            try {
                // ADB forward accepts before the Android abstract socket exists.
                // The launcher waits for that socket before creating this bridge.
                source.Connect(IPAddress.Loopback, sourcePort);
                source.NoDelay = true;
                source.ReceiveTimeout = 12000;
                var input = source.GetStream();
                byte[] config = null;
                while (!stopped) {
                    byte[] header = ReadExact(input, 12);
                    ulong flags = BigEndian(header, 0, 8);
                    ulong length = BigEndian(header, 8, 4);
                    if (length == 0 || length > 8 * 1024 * 1024 || (flags >> 63) != 0)
                        throw new InvalidDataException("Invalid scrcpy video packet");
                    byte[] data = ReadExact(input, (int)length);
                    if ((flags & (1UL << 62)) != 0) {
                        if (length > 65536) throw new InvalidDataException("Oversized codec configuration");
                        config = data; continue;
                    }
                    if (config == null) continue;
                    var frame = new VideoFrame { Data = data, Config = config,
                        Timestamp = (long)(flags & ((1UL << 61) - 1)), Key = (flags & (1UL << 61)) != 0 };
                    Interlocked.Exchange(ref lastFrameTicks, DateTime.UtcNow.Ticks);
                    Interlocked.Increment(ref frameCount);
                    foreach (var viewer in viewers.Keys) {
                        if (!viewer.Started && !frame.Key) continue;
                        viewer.Started = true;
                        if (Interlocked.Add(ref viewer.PendingBytes, data.Length) > 8 * 1024 * 1024 || !viewer.Queue.TryAdd(frame))
                            Drop(viewer); // Slow consumers reconnect at the next IDR.
                    }
                }
            } catch (Exception error) { if (!stopped) Error = error.Message; }
            finally {
                source.Close();
                foreach (var viewer in viewers.Keys) Drop(viewer);
            }
        }
        void Accept() {
            while (!stopped) {
                try {
                    var socket = listener.AcceptTcpClient();
                    if (viewers.Count >= 8) { socket.Close(); continue; }
                    var viewer = new Viewer { Socket = socket };
                    viewers.TryAdd(viewer, 0);
                    Task.Run(() => Serve(viewer));
                } catch (SocketException) { if (stopped) return; }
                  catch (ObjectDisposedException) { return; }
            }
        }
        void Serve(Viewer viewer) {
            try {
                viewer.Socket.ReceiveTimeout = 3000;
                viewer.Socket.SendTimeout = 2000;
                viewer.Socket.NoDelay = true;
                var stream = viewer.Socket.GetStream();
                var request = new StringBuilder();
                while (request.Length < 4096) {
                    int value = stream.ReadByte();
                    if (value < 0) return;
                    request.Append((char)value);
                    if (request.Length >= 4 && request.ToString().EndsWith("\r\n\r\n")) break;
                }
                string line = request.ToString().Split('\r')[0];
                if (line != "GET " + path + " HTTP/1.1" && line != "GET " + path + " HTTP/1.0") {
                    byte[] forbidden = Encoding.ASCII.GetBytes("HTTP/1.0 403 Forbidden\r\nContent-Length: 0\r\n\r\n");
                    stream.Write(forbidden, 0, forbidden.Length); return;
                }
                byte[] response = Encoding.ASCII.GetBytes("HTTP/1.0 200 OK\r\nContent-Type: video/mp2t\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n");
                stream.Write(response, 0, response.Length);
                var muxer = new TransportStream();
                VideoFrame frame;
                while (!stopped && viewer.Queue.TryTake(out frame, 12000)) {
                    Interlocked.Add(ref viewer.PendingBytes, -frame.Data.Length);
                    var bytes = muxer.Encode(frame);
                    stream.Write(bytes, 0, bytes.Length);
                }
            } catch (Exception) { /* timeout/disconnect affects only this viewer */ }
            finally { Drop(viewer); }
        }
        void Drop(Viewer viewer) {
            byte unused;
            viewers.TryRemove(viewer, out unused);
            viewer.Socket.Close();
        }
        public void Dispose() {
            stopped = true; listener.Stop(); source.Close();
            foreach (var viewer in viewers.Keys) Drop(viewer);
        }
    }
}

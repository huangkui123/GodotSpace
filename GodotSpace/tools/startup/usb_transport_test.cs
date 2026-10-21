using System;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using GodotSpace.Usb;

public static class UsbTransportTests {
    static void Check(bool condition, string message) { if (!condition) throw new Exception(message); }
    static byte[] Read(Stream stream, int count) {
        var bytes = new byte[count];
        for (int at = 0; at < count;) {
            int n = stream.Read(bytes, at, count - at);
            if (n == 0) throw new EndOfStreamException();
            at += n;
        }
        return bytes;
    }
    static string Header(Stream stream) {
        var result = new StringBuilder();
        while (result.Length < 4096) {
            result.Append((char)Read(stream, 1)[0]);
            if (result.ToString().EndsWith("\r\n\r\n")) return result.ToString();
        }
        throw new Exception("Missing HTTP header terminator");
    }
    static TcpClient Viewer(CastBridge bridge, string token, bool accepted) {
        var client = new TcpClient("127.0.0.1", bridge.Port);
        client.ReceiveTimeout = 3000;
        var request = Encoding.ASCII.GetBytes("GET /" + token + "/video.ts HTTP/1.0\r\n\r\n");
        client.GetStream().Write(request, 0, request.Length);
        Check(Header(client.GetStream()).StartsWith(accepted ? "HTTP/1.0 200" : "HTTP/1.0 403"), "HTTP authorization");
        return client;
    }
    static void Send(Stream stream, ulong flags, byte[] body) {
        byte[] header = new byte[12];
        for (int i = 0; i < 8; i++) header[i] = (byte)(flags >> (56 - i * 8));
        for (int i = 0; i < 4; i++) header[8 + i] = (byte)(body.Length >> (24 - i * 8));
        // Force fragmented packet headers. A read must not assume one TCP read
        // corresponds to one Android packet.
        stream.Write(header, 0, 3); stream.Write(header, 3, 9);
        stream.Write(body, 0, body.Length);
    }
    static void VerifyTs(byte[] data) {
        Check(data.Length % 188 == 0, "TS alignment");
        for (int i = 0; i < data.Length; i += 188) Check(data[i] == 0x47, "TS sync");
        for (int table = 0; table < 2; table++) {
            int packet = table * 188;
            int start = packet + 4 + data[packet + 4] + 1 + 1;
            int length = (((data[start + 1] & 15) << 8) | data[start + 2]) + 3;
            uint crc = 0xffffffff;
            for (int n = start; n < start + length; n++) {
                crc ^= (uint)data[n] << 24;
                for (int bit = 0; bit < 8; bit++) crc = (crc << 1) ^ ((crc & 0x80000000) != 0 ? 0x04c11db7u : 0);
            }
            Check(crc == 0, "PAT/PMT CRC");
        }
        int pes = 2 * 188 + 5 + data[2 * 188 + 4];
        Check(data[pes + 9] == 0x21 && data[pes + 10] == 0 && data[pes + 11] == 1 &&
            data[pes + 12] == 0 && data[pes + 13] == 1, "New viewer timestamps start at zero");
    }
    public static void Run() {
        var frame = new VideoFrame { Timestamp = 900000000, Key = true,
            Config = new byte[] {0,0,0,1,0x67}, Data = new byte[] {0,0,0,1,0x65,0x88} };
        var mux = new TransportStream();
        byte[] ts = mux.Encode(frame);
        VerifyTs(ts);
        var fakeAdb = new TcpListener(IPAddress.Loopback, 0);
        fakeAdb.Start();
        string token = new string('a', 48);
        using (var bridge = new CastBridge(((IPEndPoint)fakeAdb.LocalEndpoint).Port, token, false))
        using (var source = fakeAdb.AcceptTcpClient()) {
            using (var rejected = Viewer(bridge, new string('b', 48), false)) { }
            using (var first = Viewer(bridge, token, true)) {
                Send(source.GetStream(), 1UL << 62, frame.Config);
                Send(source.GetStream(), (1UL << 61) | (ulong)frame.Timestamp, frame.Data);
                VerifyTs(Read(first.GetStream(), ts.Length));
                using (var late = Viewer(bridge, token, true)) {
                    Send(source.GetStream(), (ulong)frame.Timestamp + 33333, frame.Data); // wait for IDR
                    Send(source.GetStream(), (1UL << 61) | ((ulong)frame.Timestamp + 1000000), frame.Data);
                    VerifyTs(Read(late.GetStream(), ts.Length));
                    Check(bridge.IsLive && bridge.FrameCount >= 3, "Real frame freshness");
                }
                source.Close();
                Check(SpinWait.SpinUntil(() => bridge.Error.Length > 0, 3000), "USB disconnect reported");
            }
        }
        fakeAdb.Stop();
        var destination = new TcpListener(IPAddress.Loopback, 0);
        destination.Start();
        using (var relay = new CameraRelay("127.0.0.1", ((IPEndPoint)destination.LocalEndpoint).Port))
        using (var camera = new TcpClient("127.0.0.1", relay.Port))
        using (var server = destination.AcceptTcpClient()) {
            camera.ReceiveTimeout = server.ReceiveTimeout = 3000;
            byte[] payload = new byte[90000];
            new Random(123).NextBytes(payload);
            var send = Task.Run(() => camera.GetStream().Write(payload, 0, payload.Length));
            byte[] received = Read(server.GetStream(), payload.Length);
            Check(Convert.ToBase64String(payload) == Convert.ToBase64String(received), "Camera payload forwarded intact");
            byte[] ack = Encoding.ASCII.GetBytes("PAA1test");
            server.GetStream().Write(ack, 0, ack.Length);
            Check(Encoding.ASCII.GetString(Read(camera.GetStream(), ack.Length)) == "PAA1test", "ACK forwarded intact");
            send.Wait();
        }
        destination.Stop();
    }
}

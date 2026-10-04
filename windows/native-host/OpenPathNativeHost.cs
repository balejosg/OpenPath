// OpenPath Windows native messaging host.
//
// Compiled on the target machine by the OpenPath installer/update with the
// in-box .NET Framework compiler (csc.exe v4.0.30319). C# 5 only: no string
// interpolation, no null-conditional operators, no nameof. The only framework
// reference is System.dll besides mscorlib; JSON is parsed and written by the
// small reader/writer below so no NuGet or optional assembly is required.
//
// Wire protocol parity with windows/scripts/OpenPath-NativeHost.ps1:
//   - 4-byte little-endian length + UTF-8 JSON frames;
//   - same action names, response shapes, protocolVersion and id echo;
//   - same per-user log (%LOCALAPPDATA%\OpenPath\native-host.log, 256 KiB cap,
//     one .1 rotation) and the stage lines the lane depends on.
//
// The SYSTEM worker stays authoritative for every policy application: this host
// validates syntactically, reads staged state and queues requests only.

using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Net;
using System.Text;
using System.Threading;

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        // ------------------------------------------------------------------
        // JSON (parse + write). Values are kept in a small value model so the
        // id echo preserves the original token type and numbers keep their
        // integer/double nature.
        // ------------------------------------------------------------------

        internal sealed class JsonObject
        {
            private readonly List<string> _keys = new List<string>();
            private readonly List<object> _values = new List<object>();

            public int Count { get { return _keys.Count; } }

            public string KeyAt(int index) { return _keys[index]; }
            public object ValueAt(int index) { return _values[index]; }

            public void Add(string key, object value)
            {
                _keys.Add(key);
                _values.Add(value);
            }

            public void Set(string key, object value)
            {
                for (int i = 0; i < _keys.Count; i++)
                {
                    if (string.Equals(_keys[i], key, StringComparison.Ordinal))
                    {
                        _values[i] = value;
                        return;
                    }
                }
                Add(key, value);
            }

            public bool ContainsKey(string key)
            {
                for (int i = 0; i < _keys.Count; i++)
                {
                    if (string.Equals(_keys[i], key, StringComparison.Ordinal)) { return true; }
                }
                return false;
            }

            public object Get(string key)
            {
                for (int i = 0; i < _keys.Count; i++)
                {
                    if (string.Equals(_keys[i], key, StringComparison.Ordinal)) { return _values[i]; }
                }
                return null;
            }

            public object Get(string key, object fallback)
            {
                object value = Get(key);
                return value == null ? fallback : value;
            }
        }

        internal static string JsonString(object value)
        {
            StringBuilder builder = new StringBuilder();
            JsonWrite(builder, value, 0);
            return builder.ToString();
        }

        private static void JsonWrite(StringBuilder builder, object value, int depth)
        {
            if (depth > 32) { throw new InvalidOperationException("json-depth"); }
            if (value == null) { builder.Append("null"); return; }
            if (value is bool) { builder.Append(((bool)value) ? "true" : "false"); return; }
            if (value is int) { builder.Append(((int)value).ToString(CultureInfo.InvariantCulture)); return; }
            if (value is long) { builder.Append(((long)value).ToString(CultureInfo.InvariantCulture)); return; }
            if (value is double)
            {
                double number = (double)value;
                if (double.IsNaN(number) || double.IsInfinity(number)) { builder.Append("null"); return; }
                builder.Append(number.ToString("R", CultureInfo.InvariantCulture));
                return;
            }
            if (value is string) { JsonWriteString(builder, (string)value); return; }
            JsonObject obj = value as JsonObject;
            if (obj != null)
            {
                builder.Append('{');
                for (int i = 0; i < obj.Count; i++)
                {
                    if (i > 0) { builder.Append(','); }
                    JsonWriteString(builder, obj.KeyAt(i));
                    builder.Append(':');
                    JsonWrite(builder, obj.ValueAt(i), depth + 1);
                }
                builder.Append('}');
                return;
            }
            System.Collections.IEnumerable items = value as System.Collections.IEnumerable;
            if (items != null)
            {
                builder.Append('[');
                bool first = true;
                foreach (object item in items)
                {
                    if (!first) { builder.Append(','); }
                    first = false;
                    JsonWrite(builder, item, depth + 1);
                }
                builder.Append(']');
                return;
            }
            throw new InvalidOperationException("json-type:" + value.GetType().FullName);
        }

        private static void JsonWriteString(StringBuilder builder, string text)
        {
            builder.Append('"');
            for (int i = 0; i < text.Length; i++)
            {
                char c = text[i];
                switch (c)
                {
                    case '"': builder.Append("\\\""); break;
                    case '\\': builder.Append("\\\\"); break;
                    case '\b': builder.Append("\\b"); break;
                    case '\f': builder.Append("\\f"); break;
                    case '\n': builder.Append("\\n"); break;
                    case '\r': builder.Append("\\r"); break;
                    case '\t': builder.Append("\\t"); break;
                    default:
                        if (c < ' ')
                        {
                            builder.Append("\\u");
                            builder.Append(((int)c).ToString("x4", CultureInfo.InvariantCulture));
                        }
                        else
                        {
                            builder.Append(c);
                        }
                        break;
                }
            }
            builder.Append('"');
        }

        internal static object JsonParse(string text)
        {
            int index = 0;
            object value = JsonParseValue(text, ref index, 0);
            JsonSkipWhitespace(text, ref index);
            if (index < text.Length) { throw new FormatException("json-trailing-data"); }
            return value;
        }

        private static void JsonSkipWhitespace(string text, ref int index)
        {
            while (index < text.Length)
            {
                char c = text[index];
                if (c == ' ' || c == '\t' || c == '\r' || c == '\n') { index++; }
                else { break; }
            }
        }

        private static object JsonParseValue(string text, ref int index, int depth)
        {
            if (depth > 32) { throw new FormatException("json-depth"); }
            JsonSkipWhitespace(text, ref index);
            if (index >= text.Length) { throw new FormatException("json-eof"); }
            char c = text[index];
            switch (c)
            {
                case '{': return JsonParseObject(text, ref index, depth);
                case '[': return JsonParseArray(text, ref index, depth);
                case '"': return JsonParseString(text, ref index);
                case 't':
                    JsonExpect(text, ref index, "true");
                    return true;
                case 'f':
                    JsonExpect(text, ref index, "false");
                    return false;
                case 'n':
                    JsonExpect(text, ref index, "null");
                    return null;
                default:
                    return JsonParseNumber(text, ref index);
            }
        }

        private static void JsonExpect(string text, ref int index, string token)
        {
            if (index + token.Length > text.Length || string.CompareOrdinal(text, index, token, 0, token.Length) != 0)
            {
                throw new FormatException("json-token");
            }
            index += token.Length;
        }

        private static JsonObject JsonParseObject(string text, ref int index, int depth)
        {
            JsonObject obj = new JsonObject();
            index++; // '{'
            JsonSkipWhitespace(text, ref index);
            if (index < text.Length && text[index] == '}') { index++; return obj; }
            while (true)
            {
                JsonSkipWhitespace(text, ref index);
                if (index >= text.Length || text[index] != '"') { throw new FormatException("json-key"); }
                string key = JsonParseString(text, ref index);
                JsonSkipWhitespace(text, ref index);
                if (index >= text.Length || text[index] != ':') { throw new FormatException("json-colon"); }
                index++;
                object value = JsonParseValue(text, ref index, depth + 1);
                obj.Add(key, value);
                JsonSkipWhitespace(text, ref index);
                if (index < text.Length && text[index] == ',') { index++; continue; }
                if (index < text.Length && text[index] == '}') { index++; return obj; }
                throw new FormatException("json-object");
            }
        }

        private static List<object> JsonParseArray(string text, ref int index, int depth)
        {
            List<object> items = new List<object>();
            index++; // '['
            JsonSkipWhitespace(text, ref index);
            if (index < text.Length && text[index] == ']') { index++; return items; }
            while (true)
            {
                object value = JsonParseValue(text, ref index, depth + 1);
                items.Add(value);
                JsonSkipWhitespace(text, ref index);
                if (index < text.Length && text[index] == ',') { index++; continue; }
                if (index < text.Length && text[index] == ']') { index++; return items; }
                throw new FormatException("json-array");
            }
        }

        private static string JsonParseString(string text, ref int index)
        {
            index++; // '"'
            StringBuilder builder = new StringBuilder();
            while (index < text.Length)
            {
                char c = text[index++];
                if (c == '"') { return builder.ToString(); }
                if (c == '\\')
                {
                    if (index >= text.Length) { throw new FormatException("json-escape"); }
                    char e = text[index++];
                    switch (e)
                    {
                        case '"': builder.Append('"'); break;
                        case '\\': builder.Append('\\'); break;
                        case '/': builder.Append('/'); break;
                        case 'b': builder.Append('\b'); break;
                        case 'f': builder.Append('\f'); break;
                        case 'n': builder.Append('\n'); break;
                        case 'r': builder.Append('\r'); break;
                        case 't': builder.Append('\t'); break;
                        case 'u':
                            if (index + 4 > text.Length) { throw new FormatException("json-unicode"); }
                            int code = int.Parse(text.Substring(index, 4), NumberStyles.HexNumber, CultureInfo.InvariantCulture);
                            builder.Append((char)code);
                            index += 4;
                            break;
                        default: throw new FormatException("json-escape");
                    }
                    continue;
                }
                builder.Append(c);
            }
            throw new FormatException("json-string");
        }

        private static object JsonParseNumber(string text, ref int index)
        {
            int start = index;
            if (index < text.Length && (text[index] == '-' || text[index] == '+')) { index++; }
            bool isDouble = false;
            while (index < text.Length)
            {
                char c = text[index];
                if (c >= '0' && c <= '9') { index++; continue; }
                if (c == '.' || c == 'e' || c == 'E' || c == '+' || c == '-') { isDouble = true; index++; continue; }
                break;
            }
            string token = text.Substring(start, index - start);
            if (!isDouble)
            {
                long asLong;
                if (long.TryParse(token, NumberStyles.Integer, CultureInfo.InvariantCulture, out asLong))
                {
                    if (asLong >= int.MinValue && asLong <= int.MaxValue) { return (int)asLong; }
                    return asLong;
                }
            }
            double asDouble;
            if (!double.TryParse(token, NumberStyles.Float, CultureInfo.InvariantCulture, out asDouble))
            {
                throw new FormatException("json-number");
            }
            return asDouble;
        }

        // ------------------------------------------------------------------
        // Helpers shared by every action.
        // ------------------------------------------------------------------

        internal static string GetString(object value)
        {
            if (value == null) { return ""; }
            if (value is string) { return (string)value; }
            if (value is bool) { return ((bool)value) ? "True" : "False"; }
            return Convert.ToString(value, CultureInfo.InvariantCulture);
        }

        internal static long GetLong(object value, long fallback)
        {
            if (value == null) { return fallback; }
            if (value is int) { return (int)value; }
            if (value is long) { return (long)value; }
            if (value is double) { return (long)(double)value; }
            long parsed;
            if (long.TryParse(GetString(value), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)) { return parsed; }
            return fallback;
        }

        internal static double GetDouble(object value, double fallback)
        {
            if (value == null) { return fallback; }
            if (value is int) { return (int)value; }
            if (value is long) { return (long)value; }
            if (value is double) { return (double)value; }
            double parsed;
            if (double.TryParse(GetString(value), NumberStyles.Float, CultureInfo.InvariantCulture, out parsed)) { return parsed; }
            return fallback;
        }

        internal static bool GetBool(object value, bool fallback)
        {
            if (value == null) { return fallback; }
            if (value is bool) { return (bool)value; }
            string text = GetString(value).Trim().ToLowerInvariant();
            if (text == "true" || text == "1" || text == "yes" || text == "on") { return true; }
            if (text == "false" || text == "0" || text == "no" || text == "off" || text == "") { return false; }
            return fallback;
        }

        internal static string GetField(JsonObject obj, string key)
        {
            if (obj == null) { return ""; }
            return GetString(obj.Get(key));
        }

        internal static bool HasField(JsonObject obj, string key)
        {
            return obj != null && obj.ContainsKey(key);
        }

        internal static JsonObject AsObject(object value)
        {
            return value as JsonObject;
        }

        internal static List<object> AsArray(object value)
        {
            List<object> items = value as List<object>;
            if (items != null) { return items; }
            // In-code responses use List<string> for lists; JSON parsing produces
            // List<object>. Both must behave like arrays (a bare 'as List<object>'
            // silently emptied every List<string> list, which made the recent
            // captive-portal success path treat its host lists as empty).
            System.Collections.IEnumerable enumerable = value as System.Collections.IEnumerable;
            if (enumerable == null || value is string) { return null; }
            List<object> converted = new List<object>();
            foreach (object item in enumerable) { converted.Add(item); }
            return converted;
        }

        internal static string Sha256Hex(byte[] bytes)
        {
            using (System.Security.Cryptography.SHA256 sha = System.Security.Cryptography.SHA256.Create())
            {
                byte[] hash = sha.ComputeHash(bytes);
                StringBuilder builder = new StringBuilder(hash.Length * 2);
                for (int i = 0; i < hash.Length; i++) { builder.Append(hash[i].ToString("x2", CultureInfo.InvariantCulture)); }
                return builder.ToString();
            }
        }

        internal static string Sha256File(string path)
        {
            try
            {
                if (!File.Exists(path)) { return ""; }
                byte[] bytes = File.ReadAllBytes(path);
                return Sha256Hex(bytes);
            }
            catch { return ""; }
        }

        internal static byte[] ReadAllBytesShared(string path)
        {
            // The agent may hold these files open for append/write; deny nothing.
            using (FileStream stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                long length = stream.Length;
                if (length > int.MaxValue) { length = int.MaxValue; }
                byte[] buffer = new byte[length];
                int offset = 0;
                while (offset < buffer.Length)
                {
                    int read = stream.Read(buffer, offset, buffer.Length - offset);
                    if (read <= 0) { break; }
                    offset += read;
                }
                if (offset != buffer.Length)
                {
                    byte[] trimmed = new byte[offset];
                    Array.Copy(buffer, trimmed, offset);
                    return trimmed;
                }
                return buffer;
            }
        }

        internal static string ReadAllTextShared(string path)
        {
            try
            {
                if (!File.Exists(path)) { return ""; }
                return Encoding.UTF8.GetString(ReadAllBytesShared(path));
            }
            catch { return ""; }
        }

        internal static void WriteAllTextUtf8(string path, string text)
        {
            string directory = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory))
            {
                Directory.CreateDirectory(directory);
            }
            File.WriteAllText(path, text, new UTF8Encoding(false));
        }
    }
}

// Part 2: paths, state, logging, framing. Continuing the partial Program class.

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        private const int LogMaxBytes = 262144;
        private const long MaxMessageBytes = 1048576;
        private const int MaxDomains = 50;
        private const int BatchMaxEntries = 20;
        private const string ActionAllowLocal = "allow-local-runtime-dependency";
        private const string ActionAllowLocalBatch = "allow-local-runtime-dependency-batch";
        private const string ActionCheckLocal = "check-local-runtime-dependency";
        private const string QueueVersion = "1";
        private const string SourceFirefoxWebRequestLocal = "firefox-webrequest-local";

        private static string _nativeRoot;
        private static string _openPathRoot;
        private static string _statePath;
        private static string _whitelistPath;
        private static string _logPath;
        private static readonly System.Diagnostics.Stopwatch ScriptStopwatch = System.Diagnostics.Stopwatch.StartNew();
        private static DateTime _processStartUtc = DateTime.MinValue;

        private static string GetNativeRoot()
        {
            if (_nativeRoot == null)
            {
                string location = typeof(Program).Assembly.Location;
                _nativeRoot = string.IsNullOrEmpty(location) ? Directory.GetCurrentDirectory() : Path.GetDirectoryName(location);
            }
            return _nativeRoot;
        }

        private static string GetOpenPathRoot()
        {
            if (_openPathRoot != null) { return _openPathRoot; }
            string nativeRoot = GetNativeRoot();
            // Parity with Resolve-OpenPathNativeHostRoot: the staged native dir is
            // <root>\browser-extension\firefox\native.
            string stagedState = Path.Combine(nativeRoot, "NativeHost.State.ps1");
            if (File.Exists(stagedState))
            {
                _openPathRoot = Path.GetFullPath(Path.Combine(nativeRoot, "..", "..", ".."));
                return _openPathRoot;
            }
            string[] candidates = new string[]
            {
                Path.Combine(nativeRoot, ".."),
                Path.Combine(nativeRoot, "..", "..", "..")
            };
            foreach (string candidate in candidates)
            {
                string resolved = Path.GetFullPath(candidate);
                if (File.Exists(Path.Combine(resolved, "lib", "internal", "NativeHost.State.ps1")))
                {
                    _openPathRoot = resolved;
                    return _openPathRoot;
                }
            }
            _openPathRoot = Path.GetFullPath(Path.Combine(nativeRoot, "..", "..", ".."));
            return _openPathRoot;
        }

        private static string GetStatePath() { if (_statePath == null) { _statePath = Path.Combine(GetNativeRoot(), "native-state.json"); } return _statePath; }
        private static string GetWhitelistPath() { if (_whitelistPath == null) { _whitelistPath = Path.Combine(GetNativeRoot(), "whitelist.txt"); } return _whitelistPath; }

        private static string GetLogPath()
        {
            if (_logPath != null) { return _logPath; }
            string basePath = Environment.GetEnvironmentVariable("LOCALAPPDATA");
            if (string.IsNullOrEmpty(basePath) || basePath.Trim().Length == 0)
            {
                basePath = Path.GetTempPath();
            }
            if (string.IsNullOrEmpty(basePath) || basePath.Trim().Length == 0)
            {
                _logPath = Path.Combine(GetNativeRoot(), "native-host.log");
                return _logPath;
            }
            _logPath = Path.Combine(Path.Combine(basePath, "OpenPath"), "native-host.log");
            return _logPath;
        }

        private static string ForEachProcessStart()
        {
            if (_processStartUtc == DateTime.MinValue)
            {
                try
                {
                    System.Diagnostics.Process process = System.Diagnostics.Process.GetCurrentProcess();
                    _processStartUtc = process.StartTime.ToUniversalTime();
                }
                catch
                {
                    _processStartUtc = DateTime.MinValue;
                }
            }
            return null;
        }

        private static int GetProcessElapsedMs()
        {
            ForEachProcessStart();
            if (_processStartUtc == DateTime.MinValue) { return 0; }
            try { return (int)(DateTime.UtcNow - _processStartUtc).TotalMilliseconds; }
            catch { return 0; }
        }

        // Writes one native-host log line. Format matches Write-NativeHostLog in
        // the PowerShell host: [timestamp] [+Nms script] [proc=Nms] message.
        private static void WriteCompatLog(string message)
        {
            try
            {
                string safe = message == null ? "" : message;
                safe = System.Text.RegularExpressions.Regex.Replace(safe, "(?i)(token=)[^&\\s]+", "${1}<redacted>");
                safe = System.Text.RegularExpressions.Regex.Replace(safe, "(?i)/w/[A-Za-z0-9._-]{8,}", "/w/<redacted>");

                string timestamp = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss.fff", CultureInfo.InvariantCulture);
                string line = "[" + timestamp + "] [+" + ScriptStopwatch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture) + "ms script] [proc=" + GetProcessElapsedMs().ToString(CultureInfo.InvariantCulture) + "ms] " + safe + "\r\n";
                byte[] bytes = Encoding.UTF8.GetBytes(line);
                string logPath = GetLogPath();
                string directory = Path.GetDirectoryName(logPath);
                if (!string.IsNullOrEmpty(directory) && !Directory.Exists(directory)) { Directory.CreateDirectory(directory); }

                try
                {
                    if (File.Exists(logPath) && new FileInfo(logPath).Length >= LogMaxBytes)
                    {
                        File.Copy(logPath, logPath + ".1", true);
                        File.Delete(logPath);
                    }
                }
                catch { }

                for (int attempt = 1; attempt <= 5; attempt++)
                {
                    FileStream stream = null;
                    try
                    {
                        stream = new FileStream(logPath, FileMode.Append, FileAccess.Write, FileShare.ReadWrite | FileShare.Delete);
                        stream.Write(bytes, 0, bytes.Length);
                        break;
                    }
                    catch
                    {
                        if (attempt < 5) { Thread.Sleep(50 * attempt); }
                    }
                    finally
                    {
                        if (stream != null) { stream.Dispose(); }
                    }
                }
            }
            catch { }
        }

        // Formats an action-log value like Format-NativeHostActionLogValue.
        private static string FormatActionLogValue(string value)
        {
            string text = value == null ? "" : value.Replace("\r", " ").Replace("\n", " ").Replace("\t", " ");
            text = System.Text.RegularExpressions.Regex.Replace(text, "(?i)(token=)[^&\\s]+", "${1}<redacted>");
            text = System.Text.RegularExpressions.Regex.Replace(text, "(?i)/w/[A-Za-z0-9._-]{8,}", "/w/<redacted>");
            text = System.Text.RegularExpressions.Regex.Replace(text, "\\s+", " ");
            if (text.Length > 240) { text = text.Substring(0, 240); }
            return text;
        }

        private static void WriteActionLog(string action, List<string> domains, bool success, string message, string errorMessage, long elapsedMs, JsonObject extraFields)
        {
            try
            {
                List<string> parts = new List<string>();
                parts.Add("action=" + action);
                parts.Add("success=" + (success ? "true" : "false"));
                parts.Add("elapsedMs=" + elapsedMs.ToString(CultureInfo.InvariantCulture));
                parts.Add("domains=" + string.Join(",", GetValidDomains(domains).ToArray()));
                if (!string.IsNullOrEmpty(message)) { parts.Add("message=" + FormatActionLogValue(message)); }
                if (!string.IsNullOrEmpty(errorMessage)) { parts.Add("error=" + FormatActionLogValue(errorMessage)); }
                if (extraFields != null)
                {
                    List<string> keys = new List<string>();
                    for (int i = 0; i < extraFields.Count; i++) { keys.Add(extraFields.KeyAt(i)); }
                    keys.Sort(StringComparer.Ordinal);
                    foreach (string key in keys)
                    {
                        if (!System.Text.RegularExpressions.Regex.IsMatch(key, "^[A-Za-z][A-Za-z0-9]*$")) { continue; }
                        string value = GetString(extraFields.Get(key));
                        if (string.IsNullOrEmpty(value) || value.Trim().Length == 0) { continue; }
                        parts.Add(key + "=" + FormatActionLogValue(value));
                    }
                }
                WriteCompatLog("Native host " + string.Join(" ", parts.ToArray()));
            }
            catch { }
        }

        private static void WriteStageLog(string stage, List<string> domains, string message, long elapsedMs, JsonObject fields)
        {
            try
            {
                List<string> parts = new List<string>();
                parts.Add("stage=" + stage);
                if (elapsedMs > 0) { parts.Add("elapsedMs=" + elapsedMs.ToString(CultureInfo.InvariantCulture)); }
                List<string> safeDomains = GetValidDomains(domains);
                if (safeDomains.Count > 0) { parts.Add("domains=" + string.Join(",", safeDomains.ToArray())); }
                if (!string.IsNullOrEmpty(message)) { parts.Add("message=" + FormatActionLogValue(message)); }
                if (fields != null)
                {
                    List<string> keys = new List<string>();
                    for (int i = 0; i < fields.Count; i++) { keys.Add(fields.KeyAt(i)); }
                    keys.Sort(StringComparer.Ordinal);
                    foreach (string key in keys)
                    {
                        if (!System.Text.RegularExpressions.Regex.IsMatch(key, "^[A-Za-z][A-Za-z0-9]*$")) { continue; }
                        string value = GetString(fields.Get(key));
                        if (string.IsNullOrEmpty(value) || value.Trim().Length == 0) { continue; }
                        parts.Add(key + "=" + FormatActionLogValue(value));
                    }
                }
                WriteCompatLog("Native host " + string.Join(" ", parts.ToArray()));
            }
            catch { }
        }

        // ------------------------------------------------------------------
        // Framing
        // ------------------------------------------------------------------

        private static object ReadMessage()
        {
            Stream stdin = Console.OpenStandardInput();
            byte[] lengthBuffer = new byte[4];
            int read = 0;
            while (read < 4)
            {
                int chunk = stdin.Read(lengthBuffer, read, 4 - read);
                if (chunk <= 0) { return null; }
                read += chunk;
            }
            int length = BitConverter.ToInt32(lengthBuffer, 0);
            if (length <= 0 || length > MaxMessageBytes) { return null; }
            byte[] payload = new byte[length];
            int offset = 0;
            while (offset < length)
            {
                int chunk = stdin.Read(payload, offset, length - offset);
                if (chunk <= 0) { return null; }
                offset += chunk;
            }
            string json = Encoding.UTF8.GetString(payload);
            return JsonParse(json);
        }

        private static void WriteMessage(JsonObject message)
        {
            Stream stdout = Console.OpenStandardOutput();
            string json = JsonString(message);
            byte[] bytes = Encoding.UTF8.GetBytes(json);
            byte[] lengthBytes = BitConverter.GetBytes(bytes.Length);
            stdout.Write(lengthBytes, 0, lengthBytes.Length);
            stdout.Write(bytes, 0, bytes.Length);
            stdout.Flush();
        }

        // ------------------------------------------------------------------
        // State, whitelist sections, config switches
        // ------------------------------------------------------------------

        private static JsonObject ReadNativeState()
        {
            if (!File.Exists(GetStatePath())) { return new JsonObject(); }
            try
            {
                object parsed = JsonParse(ReadAllTextShared(GetStatePath()));
                JsonObject obj = parsed as JsonObject;
                return obj == null ? new JsonObject() : obj;
            }
            catch
            {
                WriteCompatLog("Failed to parse native state");
                return new JsonObject();
            }
        }

        private sealed class WhitelistSections
        {
            public List<string> Whitelist = new List<string>();
            public List<string> BlockedSubdomains = new List<string>();
            public List<string> BlockedPaths = new List<string>();
            public List<string> AllowedPaths = new List<string>();
            public bool IsDisabled;
            public bool PolicyKnown;
            public string PolicyVersion = "";
        }

        private static WhitelistSections ParseWhitelistLines(IEnumerable<string> lines)
        {
            WhitelistSections sections = new WhitelistSections();
            string section = "WHITELIST";
            foreach (string raw in lines)
            {
                string trimmed = raw == null ? "" : raw.Trim();
                if (trimmed.Length == 0) { continue; }
                if (System.Text.RegularExpressions.Regex.IsMatch(trimmed, "^#\\s*DESACTIVADO\\b")) { sections.IsDisabled = true; continue; }
                System.Text.RegularExpressions.Match header = System.Text.RegularExpressions.Regex.Match(trimmed, "^##\\s*(.+)$");
                if (header.Success) { section = header.Groups[1].Value.Trim().ToUpperInvariant(); continue; }
                if (trimmed.StartsWith("#", StringComparison.Ordinal)) { continue; }
                if (section == "WHITELIST") { sections.Whitelist.Add(trimmed); }
                else if (section == "BLOCKED-SUBDOMAINS") { sections.BlockedSubdomains.Add(trimmed); }
                else if (section == "BLOCKED-PATHS") { sections.BlockedPaths.Add(trimmed); }
                else if (section == "ALLOWED-PATHS") { sections.AllowedPaths.Add(trimmed); }
            }
            return sections;
        }

        private static WhitelistSections GetWhitelistSections()
        {
            string path = GetWhitelistPath();
            if (!File.Exists(path))
            {
                WhitelistSections missing = ParseWhitelistLines(new string[0]);
                missing.PolicyKnown = false;
                missing.PolicyVersion = "";
                return missing;
            }
            try
            {
                byte[] whitelistBytes = ReadAllBytesShared(path);
                string text = Encoding.UTF8.GetString(whitelistBytes);
                WhitelistSections sections = ParseWhitelistLines(text.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.None));
                byte[] stateBytes = new byte[0];
                if (File.Exists(GetStatePath())) { stateBytes = ReadAllBytesShared(GetStatePath()); }
                byte[] combined = new byte[whitelistBytes.Length + 1 + stateBytes.Length];
                Array.Copy(whitelistBytes, 0, combined, 0, whitelistBytes.Length);
                combined[whitelistBytes.Length] = 0;
                Array.Copy(stateBytes, 0, combined, whitelistBytes.Length + 1, stateBytes.Length);
                sections.PolicyKnown = true;
                sections.PolicyVersion = Sha256Hex(combined);
                return sections;
            }
            catch
            {
                WhitelistSections failed = ParseWhitelistLines(new string[0]);
                failed.PolicyKnown = false;
                failed.PolicyVersion = "";
                return failed;
            }
        }

        private static string ReadAgentConfigValue(string name)
        {
            try
            {
                string configPath = Path.Combine(GetOpenPathRoot(), "data", "config.json");
                if (!File.Exists(configPath)) { return null; }
                object parsed = JsonParse(ReadAllTextShared(configPath));
                JsonObject config = parsed as JsonObject;
                if (config == null || !config.ContainsKey(name)) { return null; }
                object value = config.Get(name);
                if (value is bool) { return ((bool)value) ? "true" : "false"; }
                return GetString(value);
            }
            catch { return null; }
        }

        private static bool IsConfigSwitchOn(string name)
        {
            string value = ReadAgentConfigValue(name);
            if (value == null) { return false; }
            string text = value.Trim().ToLowerInvariant();
            return text == "1" || text == "true" || text == "yes" || text == "on" || text == "disabled";
        }

        private static List<string> GetCapabilities()
        {
            List<string> capabilities = new List<string>();
            bool transportDisabled = IsConfigSwitchOn("runtimeDependencyPersistentTransportDisabled");
            bool diagnosticsDisabled = IsConfigSwitchOn("extensionDiagnosticsDisabled");
            if (!transportDisabled) { capabilities.Add("runtime-dependency-enqueue"); }
            capabilities.Add("runtime-dependency-check-batch");
            capabilities.Add("message-id-echo");
            if (!transportDisabled) { capabilities.Add("runtime-dependency-auto-reload"); }
            if (!transportDisabled && !diagnosticsDisabled) { capabilities.Add("extension-diagnostics"); }
            return capabilities;
        }

        // ------------------------------------------------------------------
        // Domain validation and policy helpers
        // ------------------------------------------------------------------

        private static string NormalizeHost(string value)
        {
            if (value == null) { return ""; }
            string normalized = value.Trim().Trim('.').ToLowerInvariant();
            if (normalized.Length == 0) { return ""; }
            if (normalized.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) { return ""; }
            if (normalized.Length < 4 || normalized.Length > 253) { return ""; }
            if (!System.Text.RegularExpressions.Regex.IsMatch(normalized, "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")) { return ""; }
            return normalized;
        }

        private static List<string> GetValidDomains(IEnumerable<string> domains)
        {
            List<string> result = new List<string>();
            if (domains == null) { return result; }
            foreach (string raw in domains)
            {
                if (result.Count >= MaxDomains) { break; }
                if (!(raw is string)) { continue; }
                string normalized = raw.Trim().TrimEnd('.').ToLowerInvariant();
                if (!System.Text.RegularExpressions.Regex.IsMatch(normalized, "^[a-z0-9.-]+$")) { continue; }
                result.Add(normalized);
            }
            return result;
        }

        private static List<string> GetMessageDomains(JsonObject message)
        {
            List<string> values = new List<string>();
            List<object> array = AsArray(message == null ? null : message.Get("domains"));
            if (array != null)
            {
                foreach (object item in array) { if (item is string) { values.Add((string)item); } }
            }
            return GetValidDomains(values);
        }

        private static HashSet<string> BuildWhitelistSet(IEnumerable<string> entries)
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (entries == null) { return set; }
            foreach (string entry in entries)
            {
                string normalized = NormalizeHost(entry);
                if (normalized.Length > 0) { set.Add(normalized); }
            }
            return set;
        }

        private static HashSet<string> BuildBlockedSubdomainSet(IEnumerable<string> entries)
        {
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            if (entries == null) { return set; }
            foreach (string entry in entries)
            {
                string normalized = NormalizeHost(entry);
                if (normalized.Length > 0) { set.Add(normalized); }
            }
            return set;
        }

        private static bool WhitelistCoversHost(string hostname, HashSet<string> set)
        {
            if (string.IsNullOrEmpty(hostname) || set == null) { return false; }
            if (set.Contains(hostname)) { return true; }
            foreach (string entry in set)
            {
                if (string.IsNullOrEmpty(entry)) { continue; }
                if (hostname.EndsWith("." + entry, StringComparison.OrdinalIgnoreCase)) { return true; }
            }
            return false;
        }

        private static bool BlockedSubdomainMatch(string domain, HashSet<string> set)
        {
            if (string.IsNullOrEmpty(domain) || set == null) { return false; }
            if (set.Contains(domain)) { return true; }
            foreach (string entry in set)
            {
                if (string.IsNullOrEmpty(entry)) { continue; }
                if (domain.EndsWith("." + entry, StringComparison.OrdinalIgnoreCase)) { return true; }
            }
            return false;
        }

        private static bool ProtectedHostMatch(string hostname, HashSet<string> set)
        {
            return WhitelistCoversHost(hostname, set);
        }

        // Runtime protected hosts: the staged host cannot load Common.Domains.ps1,
        // so the PowerShell reference only has the static catalog (probe + time +
        // Microsoft + Firefox) plus the state URLs. The compiled host mirrors the
        // reference exactly.
        private static readonly string[] MicrosoftSystemDomains = new string[]
        {
            "*.windowsupdate.com", "windowsupdate.com", "windowsupdate.microsoft.com", "update.microsoft.com",
            "delivery.mp.microsoft.com", "do.dsp.mp.microsoft.com", "api.cdp.microsoft.com", "definitionupdates.microsoft.com",
            "download.microsoft.com", "download.windowsupdate.com", "go.microsoft.com", "adl.windows.com",
            "tsfe.trafficshaping.dsp.mp.microsoft.com", "wdcp.microsoft.com", "wdcpalt.microsoft.com", "wd.microsoft.com",
            "smartscreen-prod.microsoft.com", "crl.microsoft.com", "www.microsoft.com", "msftconnecttest.com",
            "www.msftconnecttest.com", "wns.windows.com", "displaycatalog.mp.microsoft.com", "storequality.microsoft.com",
            "dsx.mp.microsoft.com", "edge.microsoft.com", "config.edge.skype.com", "iecvlist.microsoft.com",
            "manage.microsoft.com", "dm.microsoft.com", "graph.microsoft.com", "login.microsoft.com",
            "login.live.com", "login.microsoftonline.com", "aadcdn.msauth.net", "aadcdn.msftauth.net",
            "azureedge.net", "blob.core.windows.net"
        };

        private static readonly string[] FirefoxSystemDomains = new string[]
        {
            "aus5.mozilla.org", "firefox.settings.services.mozilla.com", "firefox-settings-attachments.cdn.mozilla.net",
            "content-signature-2.cdn.mozilla.net", "download.mozilla.org", "download.cdn.mozilla.net",
            "archive.mozilla.org", "ftp.mozilla.org", "safebrowsing.googleapis.com", "addons.mozilla.org",
            "versioncheck.addons.mozilla.org", "services.addons.mozilla.org", "ciscobinary.openh264.org",
            "redirector.gvt1.com", "clients2.googleusercontent.com"
        };

        private static readonly string[] CaptivePortalProbeDomains = new string[]
        {
            "detectportal.firefox.com", "connectivity-check.ubuntu.com", "captive.apple.com",
            "www.msftconnecttest.com", "msftconnecttest.com", "clients3.google.com"
        };

        private static HashSet<string> BuildProtectedHosts(JsonObject state)
        {
            HashSet<string> hosts = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            List<string> sources = new List<string>();
            sources.AddRange(CaptivePortalProbeDomains);
            sources.Add("time.windows.com");
            sources.Add("time.google.com");
            sources.AddRange(MicrosoftSystemDomains);
            sources.AddRange(FirefoxSystemDomains);
            foreach (string domain in sources)
            {
                string normalized = NormalizeHost(domain);
                if (normalized.Length > 0) { hosts.Add(normalized); }
            }
            if (state != null)
            {
                foreach (string property in new string[] { "apiUrl", "requestApiUrl", "whitelistUrl" })
                {
                    string raw = GetString(state.Get(property));
                    if (raw.Trim().Length == 0) { continue; }
                    try
                    {
                        Uri uri = new Uri(raw, UriKind.Absolute);
                        string normalized = NormalizeHost(uri.Host);
                        if (normalized.Length > 0) { hosts.Add(normalized); }
                    }
                    catch { }
                }
            }
            return hosts;
        }

        private sealed class PolicyDecision
        {
            public string Decision = "blocked";
            public string Reason = "default-deny";
            // Null when the policy snapshot is unknown (PowerShell emits null).
            public bool? Active = true;
            public bool InWhitelist;
            public string Version = "";
        }

        private static PolicyDecision GetPolicyDecision(string domain, WhitelistSections sections, JsonObject state, HashSet<string> whitelistSet, HashSet<string> protectedHosts, HashSet<string> blockedSet)
        {
            PolicyDecision decision = new PolicyDecision();
            bool known = sections.PolicyKnown;
            string version = sections.PolicyVersion == null ? "" : sections.PolicyVersion;
            if (!known || version.Length == 0)
            {
                decision.Decision = "unknown";
                decision.Reason = "policy-unavailable";
                decision.Active = null;
                decision.InWhitelist = false;
                decision.Version = "";
                return decision;
            }
            if (sections.IsDisabled)
            {
                decision.Decision = "allowed";
                decision.Reason = "policy-inactive";
                decision.Active = false;
                decision.InWhitelist = true;
                decision.Version = version;
                return decision;
            }
            if (ProtectedHostMatch(domain, protectedHosts))
            {
                decision.Decision = "allowed";
                decision.Reason = "protected-infrastructure";
                decision.Active = true;
                decision.InWhitelist = true;
                decision.Version = version;
                return decision;
            }
            if (BlockedSubdomainMatch(domain, blockedSet))
            {
                decision.Decision = "blocked";
                decision.Reason = "blocked-subdomain";
                decision.Active = true;
                decision.InWhitelist = false;
                decision.Version = version;
                return decision;
            }
            if (WhitelistCoversHost(domain, whitelistSet))
            {
                decision.Decision = "allowed";
                decision.Reason = "whitelist-domain";
                decision.Active = true;
                decision.InWhitelist = true;
                decision.Version = version;
                return decision;
            }
            List<object> dependencies = AsArray(state == null ? null : state.Get("runtimeDependencyDomains"));
            if (dependencies != null)
            {
                foreach (object item in dependencies)
                {
                    if (domain == NormalizeHost(GetString(item)))
                    {
                        decision.Decision = "allowed";
                        decision.Reason = "runtime-dependency-exact";
                        decision.Active = true;
                        decision.InWhitelist = true;
                        decision.Version = version;
                        return decision;
                    }
                }
            }
            List<object> portals = AsArray(state == null ? null : state.Get("captivePortalDomains"));
            if (portals != null)
            {
                foreach (object item in portals)
                {
                    string portal = NormalizeHost(GetString(item));
                    if (portal.Length > 0 && (domain == portal || domain.EndsWith("." + portal, StringComparison.OrdinalIgnoreCase)))
                    {
                        decision.Decision = "allowed";
                        decision.Reason = "captive-portal-domain";
                        decision.Active = true;
                        decision.InWhitelist = true;
                        decision.Version = version;
                        return decision;
                    }
                }
            }
            decision.Decision = "blocked";
            decision.Reason = "default-deny";
            decision.Active = true;
            decision.InWhitelist = false;
            decision.Version = version;
            return decision;
        }

        private static bool WhitelistContainsDomains(IEnumerable<string> domains, WhitelistSections sections)
        {
            List<string> list = new List<string>();
            if (domains != null) { foreach (string domain in domains) { if (!string.IsNullOrEmpty(domain)) { list.Add(domain); } } }
            if (list.Count == 0) { return true; }
            HashSet<string> set = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (string domain in sections.Whitelist) { if (!string.IsNullOrEmpty(domain)) { set.Add(domain); } }
            foreach (string domain in list) { if (!set.Contains(domain)) { return false; } }
            return true;
        }

        private static string GetMachineName(JsonObject state)
        {
            string machineName = GetString(state.Get("machineName"));
            if (!string.IsNullOrEmpty(machineName)) { return machineName; }
            return Environment.MachineName;
        }
    }
}
// Part 3: request-setup state projection and the read-only actions
// (ping, get-hostname, get-machine-token, get-config, path/subdomain reads,
// get-policy-version). Continuing the partial Program class.

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        private sealed class SetupState
        {
            public string Status = "not_requested";
            public bool Ready;
            public bool RequestSetupRequested;
            public string ApiUrl = "";
            public string RequestApiUrl = "";
            public bool ApiUrlConfigured;
            public string WhitelistUrl = "";
            public bool WhitelistTokenConfigured;
            public string MachineToken = "";
            public string TokenState = "missing";
            public string Classroom = "";
            public string ClassroomId = "";
            public bool ClassroomConfigured;
            public string MachineName = "";
            public string Version = "";
            public List<string> MissingFields = new List<string>();
            public string DiagnosticMessage = "";
        }

        private static string TrimEndSlashes(string value)
        {
            if (value == null) { return ""; }
            string text = value.Trim().TrimEnd('/');
            return text;
        }

        private static SetupState GetRequestSetupState(JsonObject config)
        {
            string apiUrlRaw = GetString(config == null ? null : config.Get("apiUrl")).Trim();
            string requestApiUrlRaw = GetString(config == null ? null : config.Get("requestApiUrl")).Trim();
            string apiUrl = requestApiUrlRaw.Length > 0 ? requestApiUrlRaw : apiUrlRaw;
            apiUrl = TrimEndSlashes(apiUrl);
            string whitelistUrl = GetString(config == null ? null : config.Get("whitelistUrl")).Trim();
            string classroom = GetString(config == null ? null : config.Get("classroom")).Trim();
            string classroomId = GetString(config == null ? null : config.Get("classroomId")).Trim();
            string machineName = GetString(config == null ? null : config.Get("machineName")).Trim();
            string version = GetString(config == null ? null : config.Get("version")).Trim();

            SetupState state = new SetupState();
            state.ApiUrl = apiUrl;
            state.RequestApiUrl = apiUrl;
            state.WhitelistUrl = whitelistUrl;
            state.Classroom = classroom;
            state.ClassroomId = classroomId;
            state.MachineName = machineName;
            state.Version = version;
            System.Text.RegularExpressions.Match token = System.Text.RegularExpressions.Regex.Match(whitelistUrl, "/w/([^/]+)/");
            state.MachineToken = token.Success ? token.Groups[1].Value : "";

            bool requested = apiUrl.Length > 0 || whitelistUrl.Length > 0 || classroom.Length > 0 || classroomId.Length > 0;
            state.RequestSetupRequested = requested;
            if (!requested)
            {
                state.Status = "not_requested";
                state.Ready = false;
                state.DiagnosticMessage = "OpenPath request setup was not requested.";
                return state;
            }

            state.ApiUrlConfigured = System.Text.RegularExpressions.Regex.IsMatch(apiUrl, "^https?://\\S+$");
            state.WhitelistTokenConfigured = System.Text.RegularExpressions.Regex.IsMatch(whitelistUrl, "/w/[^/]+/whitelist\\.txt($|[?#].*)");
            state.ClassroomConfigured = classroom.Length > 0 || classroomId.Length > 0;
            if (!state.ApiUrlConfigured) { state.MissingFields.Add("apiUrl"); }
            if (!state.WhitelistTokenConfigured) { state.MissingFields.Add("whitelistUrl"); }
            if (!state.ClassroomConfigured) { state.MissingFields.Add("classroom"); }
            state.TokenState = state.MachineToken.Length > 0 ? "ready" : (whitelistUrl.Length > 0 ? "invalid_token_source" : "missing");
            state.Status = state.MissingFields.Count == 0 ? "ready" : "incomplete";
            state.Ready = state.Status == "ready";
            if (state.Status == "ready")
            {
                state.DiagnosticMessage = "";
            }
            else
            {
                List<string> unique = new List<string>();
                foreach (string field in state.MissingFields) { if (field.Length > 0 && !unique.Contains(field)) { unique.Add(field); } }
                state.DiagnosticMessage = unique.Count == 0
                    ? "OpenPath request setup is incomplete."
                    : "OpenPath request setup is incomplete: missing or invalid " + string.Join(", ", unique.ToArray()) + ".";
            }
            return state;
        }

        private static string ResolveDomainIp(string domain)
        {
            try
            {
                IPAddress[] addresses = Dns.GetHostAddresses(domain);
                if (addresses == null || addresses.Length == 0) { return null; }
                foreach (IPAddress address in addresses)
                {
                    if (address.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                    {
                        return address.ToString();
                    }
                }
                return addresses[0].ToString();
            }
            catch { return null; }
        }

        private static string GetNativeHostProtocolVersion() { return "2"; }

        // ------------------------------------------------------------------
        // Actions
        // ------------------------------------------------------------------

        private static JsonObject PingResponse(JsonObject state)
        {
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "ping");
            response.Add("message", "pong");
            response.Add("version", GetString(state.Get("version")));
            response.Add("protocolVersion", 2);
            response.Add("capabilities", GetCapabilities());
            return response;
        }

        private static JsonObject HostnameResponse(JsonObject state)
        {
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "get-hostname");
            response.Add("hostname", GetMachineName(state));
            return response;
        }

        private static JsonObject MachineTokenResponse(JsonObject state)
        {
            SetupState setup = GetRequestSetupState(state);
            if (string.IsNullOrEmpty(setup.MachineToken))
            {
                JsonObject failure = new JsonObject();
                failure.Add("success", false);
                failure.Add("action", "get-machine-token");
                failure.Add("error", "Machine token not available");
                return failure;
            }
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "get-machine-token");
            response.Add("token", setup.MachineToken);
            return response;
        }

        private static JsonObject ConfigResponse(JsonObject state)
        {
            SetupState setup = GetRequestSetupState(state);
            string apiUrl = setup.RequestApiUrl;
            if (string.IsNullOrEmpty(apiUrl))
            {
                JsonObject failure = new JsonObject();
                failure.Add("success", false);
                failure.Add("action", "get-config");
                failure.Add("error", "API URL is not configured");
                return failure;
            }
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "get-config");
            response.Add("apiUrl", apiUrl);
            response.Add("requestApiUrl", apiUrl);
            response.Add("fallbackApiUrls", new List<object>());
            response.Add("hostname", GetMachineName(state));
            response.Add("machineToken", setup.MachineToken);
            response.Add("whitelistUrl", setup.WhitelistUrl);
            return response;
        }

        private static JsonObject PathsResponse(WhitelistSections sections, string action, List<string> paths)
        {
            string digest = "";
            if (paths.Count > 0)
            {
                digest = Sha256Hex(Encoding.UTF8.GetBytes(string.Join("\n", paths.ToArray())));
            }
            long mtime = 0;
            if (File.Exists(GetWhitelistPath()))
            {
                mtime = (long)(File.GetLastWriteTimeUtc(GetWhitelistPath()) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            }
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", action);
            response.Add("paths", paths);
            response.Add("count", paths.Count);
            response.Add("hash", digest);
            response.Add("mtime", mtime);
            response.Add("source", GetWhitelistPath());
            return response;
        }

        private static JsonObject BlockedSubdomainsResponse(WhitelistSections sections)
        {
            List<string> subdomains = new List<string>(sections.BlockedSubdomains);
            string digest = "";
            if (subdomains.Count > 0)
            {
                digest = Sha256Hex(Encoding.UTF8.GetBytes(string.Join("\n", subdomains.ToArray())));
            }
            long mtime = 0;
            if (File.Exists(GetWhitelistPath()))
            {
                mtime = (long)(File.GetLastWriteTimeUtc(GetWhitelistPath()) - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalSeconds;
            }
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "get-blocked-subdomains");
            response.Add("subdomains", subdomains);
            response.Add("count", subdomains.Count);
            response.Add("hash", digest);
            response.Add("mtime", mtime);
            response.Add("source", GetWhitelistPath());
            return response;
        }

        private static JsonObject PolicyVersionResponse(WhitelistSections sections)
        {
            bool known = sections.PolicyKnown;
            string version = sections.PolicyVersion == null ? "" : sections.PolicyVersion;
            if (!known || version.Length == 0)
            {
                JsonObject failure = new JsonObject();
                failure.Add("success", false);
                failure.Add("action", "get-policy-version");
                failure.Add("error", "policy-unavailable");
                return failure;
            }
            JsonObject response = new JsonObject();
            response.Add("success", true);
            response.Add("action", "get-policy-version");
            response.Add("version", version);
            return response;
        }

        // check: same per-domain results as Invoke-NativeHostCheckAction.
        private static JsonObject CheckResponse(JsonObject message, WhitelistSections sections, JsonObject state)
        {
            List<string> validDomains = GetMessageDomains(message);
            InvokeAuthenticatedCaptivePortalRestoreIfNeeded();

            JsonObject response = new JsonObject();
            List<object> results = new List<object>();
            bool success = true;
            HashSet<string> whitelistSet = BuildWhitelistSet(sections.Whitelist);
            HashSet<string> protectedHosts = BuildProtectedHosts(state);
            HashSet<string> blockedSet = BuildBlockedSubdomainSet(sections.BlockedSubdomains);
            foreach (string domain in validDomains)
            {
                PolicyDecision decision = GetPolicyDecision(domain, sections, state, whitelistSet, protectedHosts, blockedSet);
                bool inWhitelist = decision.InWhitelist;
                string portalSignal = GetPortalRecoverySignal(domain, message);
                string resolvedIp = inWhitelist ? ResolveDomainIp(domain) : null;
                JsonObject result = new JsonObject();
                result.Add("domain", domain);
                result.Add("in_whitelist", inWhitelist);
                result.Add("resolved_ip", resolvedIp);
                result.Add("policy_active", decision.Active.HasValue ? (object)decision.Active.Value : null);
                result.Add("policy_decision", decision.Decision);
                result.Add("policy_reason", decision.Reason);
                result.Add("policy_version", decision.Version);
                result.Add("portal_recovery_eligible", decision.Decision == "blocked" && portalSignal != "none");
                result.Add("portal_recovery_signal", portalSignal);
                if (decision.Decision == "unknown") { success = false; }
                results.Add(result);
            }
            response.Add("success", success);
            response.Add("action", "check");
            response.Add("results", results);
            return response;
        }
    }
}
// Part 4: runtime dependency validation, queue, worker trigger and update task.

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        private static readonly string[] SensitiveFields = new string[]
        {
            "url", "resourceUrl", "target_url", "targetUrl", "originUrl", "documentUrl", "pageUrl",
            "headers", "body", "path", "query", "dom", "title", "resources", "token", "authorization",
            "cookie", "cookies"
        };

        private static string GetRuntimeDependencyQueuePath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_RUNTIME_DEPENDENCY_QUEUE_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "runtime-dependency-queue");
        }

        private static string GetRuntimeDependencyOverlayPath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_RUNTIME_DEPENDENCY_OVERLAY_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "runtime-dependency-overlay.json");
        }

        private static string GetRuntimeDependencyWorkerStatePath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_RUNTIME_DEPENDENCY_WORKER_STATE_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "runtime-dependency-worker-state.json");
        }

        private sealed class OverlaySnapshot
        {
            public int Generation;
            public int AppliedGeneration;
            public List<object> Entries = new List<object>();
        }

        private static OverlaySnapshot ReadOverlaySnapshot()
        {
            OverlaySnapshot snapshot = new OverlaySnapshot();
            try
            {
                string path = GetRuntimeDependencyOverlayPath();
                if (!File.Exists(path)) { return snapshot; }
                string raw = ReadAllTextShared(path);
                if (raw == null || raw.Trim().Length == 0) { return snapshot; }
                JsonObject parsed = JsonParse(raw) as JsonObject;
                if (parsed == null) { return snapshot; }
                snapshot.Generation = (int)GetLong(parsed.Get("generation"), 0);
                snapshot.AppliedGeneration = (int)GetLong(parsed.Get("appliedGeneration"), 0);
                List<object> entries = AsArray(parsed.Get("entries"));
                snapshot.Entries = entries == null ? new List<object>() : entries;
                return snapshot;
            }
            catch
            {
                WriteCompatLog("Failed to inspect runtime dependency overlay");
                return snapshot;
            }
        }

        private static bool EntryReady(JsonObject entry, int appliedGeneration, int documentGeneration)
        {
            if (entry == null) { return false; }
            int entryGeneration = (int)GetLong(entry.Get("generation"), 0);
            if (entryGeneration > 0) { return appliedGeneration >= entryGeneration; }
            return documentGeneration > 0 && appliedGeneration >= documentGeneration;
        }

        private static bool OverlayContainsDomain(string domain)
        {
            string normalized = NormalizeHost(domain);
            if (normalized.Length == 0) { return false; }
            OverlaySnapshot snapshot = ReadOverlaySnapshot();
            foreach (object item in snapshot.Entries)
            {
                JsonObject entry = item as JsonObject;
                if (entry == null) { continue; }
                if (NormalizeHost(GetString(entry.Get("dependencyHost"))) == normalized) { return true; }
            }
            return false;
        }

        private static JsonObject EntryState(OverlaySnapshot snapshot, string anchorHost, string dependencyHost)
        {
            JsonObject state = new JsonObject();
            state.Add("ready", false);
            state.Add("runtimeDependencyState", "pending");
            state.Add("expiresAt", "");
            foreach (object item in snapshot.Entries)
            {
                JsonObject entry = item as JsonObject;
                if (entry == null) { continue; }
                string entryDependency = NormalizeHost(GetString(entry.Get("dependencyHost")));
                string entryAnchor = NormalizeHost(GetString(entry.Get("anchorHost")));
                if (entryDependency != dependencyHost || entryAnchor != anchorHost) { continue; }
                bool ready = EntryReady(entry, snapshot.AppliedGeneration, snapshot.Generation);
                state.Set("ready", ready);
                state.Set("runtimeDependencyState", ready ? "ready" : "pending");
                string expiresAt = GetString(entry.Get("expiresAt"));
                if (expiresAt.Length > 0) { state.Set("expiresAt", expiresAt); }
                return state;
            }
            return state;
        }

        private static bool DomainsReady(List<string> domains, OverlaySnapshot snapshot)
        {
            if (domains == null || domains.Count == 0) { return true; }
            foreach (string domain in domains)
            {
                string normalized = NormalizeHost(domain);
                if (normalized.Length == 0) { return false; }
                bool matched = false;
                foreach (object item in snapshot.Entries)
                {
                    JsonObject entry = item as JsonObject;
                    if (entry == null) { continue; }
                    if (NormalizeHost(GetString(entry.Get("dependencyHost"))) != normalized) { continue; }
                    if (EntryReady(entry, snapshot.AppliedGeneration, snapshot.Generation)) { matched = true; break; }
                }
                if (!matched) { return false; }
            }
            return true;
        }

        private static bool RuntimeDependencyReady(string requestPath, List<string> domains)
        {
            if (!string.IsNullOrEmpty(requestPath) && File.Exists(requestPath)) { return false; }
            if (domains == null || domains.Count == 0) { return true; }
            return DomainsReady(domains, ReadOverlaySnapshot());
        }

        private static bool WorkerFresh(int maxAgeSeconds, int busyMaxAgeSeconds)
        {
            try
            {
                string statePath = GetRuntimeDependencyWorkerStatePath();
                if (!File.Exists(statePath)) { return false; }
                string raw = ReadAllTextShared(statePath);
                if (raw == null || raw.Trim().Length == 0) { return false; }
                JsonObject parsed = JsonParse(raw) as JsonObject;
                if (parsed == null) { return false; }
                long referenceMs = (long)(DateTime.UtcNow - new DateTime(1970, 1, 1, 0, 0, 0, DateTimeKind.Utc)).TotalMilliseconds;

                long? heartbeatMs = null;
                if (parsed.ContainsKey("heartbeatEpochMs"))
                {
                    long parsedValue = GetLong(parsed.Get("heartbeatEpochMs"), long.MinValue);
                    if (parsedValue != long.MinValue) { heartbeatMs = parsedValue; }
                }
                else if (parsed.ContainsKey("heartbeatAt"))
                {
                    DateTimeOffset value;
                    if (DateTimeOffset.TryParse(GetString(parsed.Get("heartbeatAt")), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out value))
                    {
                        heartbeatMs = value.ToUnixTimeMilliseconds();
                    }
                }
                if (heartbeatMs.HasValue)
                {
                    long ageMs = referenceMs - heartbeatMs.Value;
                    if (ageMs >= -30000 && ageMs <= Math.Max(1, maxAgeSeconds) * 1000) { return true; }
                }

                long? busySinceMs = null;
                if (parsed.ContainsKey("busySinceEpochMs"))
                {
                    long parsedValue = GetLong(parsed.Get("busySinceEpochMs"), long.MinValue);
                    if (parsedValue != long.MinValue) { busySinceMs = parsedValue; }
                }
                else if (parsed.ContainsKey("busySince"))
                {
                    DateTimeOffset value;
                    if (DateTimeOffset.TryParse(GetString(parsed.Get("busySince")), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out value))
                    {
                        busySinceMs = value.ToUnixTimeMilliseconds();
                    }
                }
                if (busySinceMs.HasValue)
                {
                    long ageMs = referenceMs - busySinceMs.Value;
                    return ageMs >= -30000 && ageMs <= Math.Max(1, busyMaxAgeSeconds) * 1000;
                }
                return false;
            }
            catch { return false; }
        }

        private sealed class CandidateValidation
        {
            public bool Valid;
            public string AnchorHost = "";
            public string DependencyHost = "";
            public string RequestType = "";
            public JsonObject Result;
        }

        private static bool HasSensitiveField(JsonObject message)
        {
            if (message == null) { return false; }
            foreach (string field in SensitiveFields)
            {
                if (message.ContainsKey(field)) { return true; }
            }
            return false;
        }

        private static bool OverlayCandidatePresent(string anchorHost, string dependencyHost)
        {
            // Test-OpenPathRuntimeDependencyOverlayContainsDomains (host copy):
            // any entry whose dependencyHost matches.
            return OverlayContainsDomain(dependencyHost);
        }

        private static string GetRuntimeDependencyMode(JsonObject message)
        {
            if (message == null || !message.ContainsKey("mode")) { return "blocking"; }
            object raw = message.Get("mode");
            if (raw == null) { return "blocking"; }
            string mode = GetString(raw).Trim().ToLowerInvariant();
            if (mode.Length == 0 || mode == "blocking") { return "blocking"; }
            if (mode == "enqueue") { return "enqueue"; }
            return "invalid";
        }

        private static JsonObject CandidateFailure(string reason, string action)
        {
            JsonObject result = new JsonObject();
            result.Add("success", false);
            result.Add("action", action);
            result.Add("error", reason);
            return result;
        }

        private static JsonObject SkippedResult(string action, string anchorHost, string dependencyHost, string requestType, string reason)
        {
            JsonObject result = new JsonObject();
            result.Add("success", true);
            result.Add("action", action);
            if (anchorHost.Length > 0) { result.Add("anchorHost", anchorHost); }
            if (dependencyHost.Length > 0) { result.Add("dependencyHost", dependencyHost); }
            if (requestType.Length > 0) { result.Add("requestType", requestType); }
            result.Add("skipped", true);
            result.Add("reason", reason);
            return result;
        }

        private static JsonObject AddReadinessToResult(JsonObject result, OverlaySnapshot snapshotOrNull)
        {
            if (result == null || !result.ContainsKey("reason")) { return result; }
            string reason = GetString(result.Get("reason"));
            if (reason == "dependency-already-whitelisted")
            {
                result.Set("ready", true);
                result.Set("runtimeDependencyState", "ready");
            }
            else if (reason == "runtime-dependency-overlay-present")
            {
                string anchorHost = result.ContainsKey("anchorHost") ? NormalizeHost(GetString(result.Get("anchorHost"))) : "";
                string dependencyHost = result.ContainsKey("dependencyHost") ? NormalizeHost(GetString(result.Get("dependencyHost"))) : "";
                bool ready = false;
                if (anchorHost.Length > 0 && dependencyHost.Length > 0)
                {
                    OverlaySnapshot snapshot = snapshotOrNull == null ? ReadOverlaySnapshot() : snapshotOrNull;
                    JsonObject entryState = EntryState(snapshot, anchorHost, dependencyHost);
                    ready = GetBool(entryState.Get("ready"), false);
                }
                result.Set("ready", ready);
                result.Set("runtimeDependencyState", ready ? "ready" : "pending");
            }
            return result;
        }

        private static CandidateValidation ValidateCandidate(JsonObject message, WhitelistSections sections, JsonObject state, HashSet<string> whitelistSet, HashSet<string> protectedHosts, HashSet<string> blockedSet, string action, bool skipOverlayCheck)
        {
            CandidateValidation validation = new CandidateValidation();
            if (HasSensitiveField(message))
            {
                validation.Valid = false;
                validation.Result = CandidateFailure("Sensitive fields are not accepted", action);
                return validation;
            }
            string anchorHost = NormalizeHost(GetString(message == null ? null : message.Get("anchorHost")));
            string dependencyHost = NormalizeHost(GetString(message == null ? null : message.Get("dependencyHost")));
            string requestType = GetString(message == null ? null : message.Get("requestType")).Trim().ToLowerInvariant();
            if (anchorHost.Length == 0 || dependencyHost.Length == 0 || requestType.Length == 0)
            {
                validation.Valid = false;
                validation.Result = CandidateFailure("Invalid runtime dependency payload", action);
                return validation;
            }
            if (requestType == "main_frame")
            {
                validation.Valid = false;
                validation.Result = CandidateFailure("main_frame dependencies are not supported", action);
                return validation;
            }
            if (anchorHost == dependencyHost)
            {
                validation.Valid = false;
                validation.Result = SkippedResult(action, "", "", "", "same-host");
                return validation;
            }
            if (!WhitelistCoversHost(anchorHost, whitelistSet))
            {
                validation.Valid = false;
                JsonObject result = new JsonObject();
                result.Add("success", false);
                result.Add("action", action);
                result.Add("anchorHost", anchorHost);
                result.Add("dependencyHost", dependencyHost);
                result.Add("requestType", requestType);
                result.Add("error", "Anchor host is not locally whitelisted");
                validation.Result = result;
                return validation;
            }
            if (ProtectedHostMatch(anchorHost, protectedHosts) || ProtectedHostMatch(dependencyHost, protectedHosts))
            {
                validation.Valid = false;
                JsonObject result = new JsonObject();
                result.Add("success", false);
                result.Add("action", action);
                result.Add("anchorHost", anchorHost);
                result.Add("dependencyHost", dependencyHost);
                result.Add("requestType", requestType);
                result.Add("error", "Protected hosts are not accepted as runtime dependencies");
                validation.Result = result;
                return validation;
            }
            if (BlockedSubdomainMatch(dependencyHost, blockedSet))
            {
                validation.Valid = false;
                JsonObject result = new JsonObject();
                result.Add("success", false);
                result.Add("action", action);
                result.Add("anchorHost", anchorHost);
                result.Add("dependencyHost", dependencyHost);
                result.Add("requestType", requestType);
                result.Add("error", "Blocked hosts are not accepted as runtime dependencies");
                validation.Result = result;
                return validation;
            }
            if (WhitelistCoversHost(dependencyHost, whitelistSet))
            {
                validation.Valid = false;
                validation.Result = SkippedResult(action, anchorHost, dependencyHost, requestType, "dependency-already-whitelisted");
                return validation;
            }
            if (!skipOverlayCheck && OverlayCandidatePresent(anchorHost, dependencyHost))
            {
                validation.Valid = false;
                validation.Result = SkippedResult(action, anchorHost, dependencyHost, requestType, "runtime-dependency-overlay-present");
                return validation;
            }
            validation.Valid = true;
            validation.AnchorHost = anchorHost;
            validation.DependencyHost = dependencyHost;
            validation.RequestType = requestType;
            return validation;
        }

        private static string FindQueueRequest(string anchorHost, string dependencyHost, string requestType)
        {
            string queuePath = GetRuntimeDependencyQueuePath();
            if (!Directory.Exists(queuePath)) { return ""; }
            string[] files = Directory.GetFiles(queuePath, "*.json");
            Array.Sort(files, StringComparer.OrdinalIgnoreCase);
            foreach (string file in files)
            {
                try
                {
                    JsonObject request = JsonParse(ReadAllTextShared(file)) as JsonObject;
                    if (request == null) { continue; }
                    string queuedAnchor = NormalizeHost(GetString(request.Get("anchorHost")));
                    string queuedDependency = NormalizeHost(GetString(request.Get("dependencyHost")));
                    string queuedRequestType = GetString(request.Get("requestType")).Trim().ToLowerInvariant();
                    if (queuedAnchor == anchorHost && queuedDependency == dependencyHost && queuedRequestType == requestType)
                    {
                        return file;
                    }
                }
                catch { continue; }
            }
            return "";
        }

        private static string WriteQueueRequest(string anchorHost, string dependencyHost, string requestType)
        {
            string queuePath = GetRuntimeDependencyQueuePath();
            Directory.CreateDirectory(queuePath);
            string existing = FindQueueRequest(anchorHost, dependencyHost, requestType);
            if (existing.Length > 0) { return existing; }
            string requestId = Guid.NewGuid().ToString("N");
            string requestPath = Path.Combine(queuePath, requestId + ".json");
            JsonObject request = new JsonObject();
            request.Add("version", QueueVersion);
            request.Add("queuedAt", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            request.Add("anchorHost", anchorHost);
            request.Add("dependencyHost", dependencyHost);
            request.Add("requestType", requestType);
            request.Add("source", SourceFirefoxWebRequestLocal);
            WriteAllTextUtf8(requestPath, JsonString(request));
            return requestPath;
        }

        private sealed class TaskRunResult
        {
            public bool Success;
            public int ExitCode;
            public int ElapsedMs;
        }

        private static TaskRunResult RunScheduledTask(string taskName)
        {
            TaskRunResult result = new TaskRunResult();
            System.Diagnostics.Stopwatch stopwatch = System.Diagnostics.Stopwatch.StartNew();
            try
            {
                System.Diagnostics.ProcessStartInfo info = new System.Diagnostics.ProcessStartInfo();
                info.FileName = "schtasks.exe";
                info.Arguments = "/Run /TN " + QuoteArgument(taskName);
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(info))
                {
                    process.StandardOutput.ReadToEnd();
                    process.StandardError.ReadToEnd();
                    process.WaitForExit(60000);
                    result.ExitCode = process.HasExited ? process.ExitCode : 1;
                    result.Success = result.ExitCode == 0;
                }
            }
            catch
            {
                result.ExitCode = 1;
                result.Success = false;
            }
            stopwatch.Stop();
            result.ElapsedMs = (int)stopwatch.ElapsedMilliseconds;
            return result;
        }

        private static string QuoteArgument(string value)
        {
            if (value == null) { return "\"\""; }
            if (value.IndexOf(' ') < 0 && value.IndexOf('"') < 0) { return value; }
            return "\"" + value.Replace("\"", "\\\"") + "\"";
        }

        private static bool WaitCondition(Func<bool> condition, int timeoutSeconds, int pollMilliseconds, out int elapsedMs)
        {
            System.Diagnostics.Stopwatch stopwatch = System.Diagnostics.Stopwatch.StartNew();
            DateTime deadline = DateTime.UtcNow.AddSeconds(timeoutSeconds);
            while (DateTime.UtcNow < deadline)
            {
                Thread.Sleep(pollMilliseconds);
                if (condition())
                {
                    stopwatch.Stop();
                    elapsedMs = (int)stopwatch.ElapsedMilliseconds;
                    return true;
                }
            }
            stopwatch.Stop();
            elapsedMs = (int)stopwatch.ElapsedMilliseconds;
            return false;
        }

        // Mirrors Invoke-UpdateTask. Returns a result object with the same fields
        // the PowerShell callers consume.
        private static JsonObject UpdateTask(List<string> domains, List<string> runtimeDependencyDomains, string runtimeDependencyRequestPath, int timeoutSeconds)
        {
            System.Diagnostics.Stopwatch stopwatch = System.Diagnostics.Stopwatch.StartNew();
            JsonObject result = null;
            bool hasRuntimeDependencyWait = runtimeDependencyDomains != null && runtimeDependencyDomains.Count > 0;
            try
            {
                WhitelistSections sections = GetWhitelistSections();
                if (!hasRuntimeDependencyWait && WhitelistContainsDomains(domains, sections))
                {
                    result = new JsonObject();
                    result.Add("success", true);
                    result.Add("action", "update-whitelist");
                    result.Add("message", "OpenPath update task triggered");
                    result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                }
                else
                {
                    bool workerFresh = hasRuntimeDependencyWait && WorkerFresh(10, 120);
                    if (workerFresh)
                    {
                        WriteStageLog("worker-fresh", runtimeDependencyDomains, "", 0, FieldObject("skippedTaskTrigger", "true"));
                        int waitMs = 0;
                        bool ready = WaitCondition(delegate
                        {
                            WhitelistSections current = GetWhitelistSections();
                            return WhitelistContainsDomains(domains, current) && RuntimeDependencyReady(runtimeDependencyRequestPath, runtimeDependencyDomains);
                        }, timeoutSeconds, 100, out waitMs);
                        result = new JsonObject();
                        if (!ready)
                        {
                            result.Add("success", false);
                            result.Add("action", "update-whitelist");
                            result.Add("error", "Runtime dependency worker did not apply expected domains: " + JoinDomainList(domains, runtimeDependencyDomains));
                            result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                            result.Add("runtimeDependencyFastPath", true);
                            result.Add("runtimeDependencyWorker", true);
                            result.Add("runtimeDependencyFallback", false);
                            result.Add("updateTaskName", "OpenPath-RuntimeDependencyWorker");
                            result.Add("updateTriggerMs", 0);
                            result.Add("updateWaitMs", waitMs);
                        }
                        else
                        {
                            result.Add("success", true);
                            result.Add("action", "update-whitelist");
                            result.Add("message", "OpenPath runtime dependency worker applied expected domains");
                            result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                            result.Add("runtimeDependencyFastPath", true);
                            result.Add("runtimeDependencyWorker", true);
                            result.Add("runtimeDependencyFallback", false);
                            result.Add("updateTaskName", "OpenPath-RuntimeDependencyWorker");
                            result.Add("updateTriggerMs", 0);
                            result.Add("updateWaitMs", waitMs);
                        }
                    }
                    else
                    {
                        string triggeredTaskName = hasRuntimeDependencyWait ? "OpenPath-RuntimeDependencyApply" : "OpenPath-Update";
                        result = RunSharedUpdateTrigger(triggeredTaskName, hasRuntimeDependencyWait, domains, runtimeDependencyDomains, runtimeDependencyRequestPath, timeoutSeconds);
                    }
                }
            }
            catch (Exception exception)
            {
                result = new JsonObject();
                result.Add("success", false);
                result.Add("action", "update-whitelist");
                result.Add("error", exception.Message);
                result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
            }
            stopwatch.Stop();
            string logMessage = GetString(result.Get("message"));
            string logError = GetString(result.Get("error"));
            WriteActionLog("update-whitelist", domains, GetBool(result.Get("success"), false), logMessage, logError, stopwatch.ElapsedMilliseconds, null);
            result.Set("elapsedMs", (int)stopwatch.ElapsedMilliseconds);
            return result;
        }

        private static JsonObject FieldObject(string key, string value)
        {
            JsonObject fields = new JsonObject();
            fields.Add(key, value);
            return fields;
        }

        private static string JoinDomainList(List<string> first, List<string> second)
        {
            List<string> all = new List<string>();
            if (first != null) { all.AddRange(first); }
            if (second != null) { all.AddRange(second); }
            return string.Join(", ", all.ToArray());
        }

        private static JsonObject RunSharedUpdateTrigger(string triggeredTaskName, bool hasRuntimeDependencyWait, List<string> domains, List<string> runtimeDependencyDomains, string runtimeDependencyRequestPath, int timeoutSeconds)
        {
            bool lockAcquired = false;
            Mutex mutex = null;
            try
            {
                mutex = new Mutex(false, @"Global\OpenPathNativeWhitelistUpdateTrigger");
                try { lockAcquired = mutex.WaitOne(0); }
                catch (AbandonedMutexException) { lockAcquired = true; }

                string taskName = triggeredTaskName;
                bool fallback = false;
                int triggerMs = 0;
                if (lockAcquired)
                {
                    TaskRunResult run = RunScheduledTask(taskName);
                    if (!run.Success && hasRuntimeDependencyWait && taskName != "OpenPath-Update")
                    {
                        fallback = true;
                        taskName = "OpenPath-Update";
                        run = RunScheduledTask(taskName);
                    }
                    triggerMs = run.ElapsedMs;
                    if (!run.Success)
                    {
                        JsonObject failed = new JsonObject();
                        failed.Add("success", false);
                        failed.Add("action", "update-whitelist");
                        failed.Add("error", "schtasks exit code " + run.ExitCode.ToString(CultureInfo.InvariantCulture));
                        failed.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                        failed.Add("runtimeDependencyFastPath", hasRuntimeDependencyWait);
                        failed.Add("runtimeDependencyFallback", fallback);
                        failed.Add("updateTaskName", taskName);
                        failed.Add("updateTriggerMs", triggerMs);
                        failed.Add("updateWaitMs", 0);
                        return failed;
                    }
                }

                int waitMs = 0;
                bool ready = WaitCondition(delegate
                {
                    WhitelistSections current = GetWhitelistSections();
                    return WhitelistContainsDomains(domains, current) && RuntimeDependencyReady(runtimeDependencyRequestPath, runtimeDependencyDomains);
                }, timeoutSeconds, 100, out waitMs);
                JsonObject result = new JsonObject();
                if (!ready)
                {
                    result.Add("success", false);
                    result.Add("action", "update-whitelist");
                    result.Add("error", "OpenPath update task did not write expected domains: " + JoinDomainList(domains, runtimeDependencyDomains));
                    result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                    result.Add("runtimeDependencyFastPath", hasRuntimeDependencyWait);
                    result.Add("runtimeDependencyFallback", fallback);
                    result.Add("updateTaskName", taskName);
                    result.Add("updateTriggerMs", triggerMs);
                    result.Add("updateWaitMs", waitMs);
                    return result;
                }
                result.Add("success", true);
                result.Add("action", "update-whitelist");
                result.Add("message", "OpenPath update task wrote expected domains");
                result.Add("domains", domains == null ? new List<object>() : new List<object>(domains.ToArray()));
                result.Add("runtimeDependencyFastPath", hasRuntimeDependencyWait);
                result.Add("runtimeDependencyFallback", fallback);
                result.Add("updateTaskName", taskName);
                result.Add("updateTriggerMs", triggerMs);
                result.Add("updateWaitMs", waitMs);
                return result;
            }
            finally
            {
                if (lockAcquired && mutex != null)
                {
                    try { mutex.ReleaseMutex(); }
                    catch { }
                }
                if (mutex != null) { mutex.Dispose(); }
            }
        }

        private static bool SendEnqueueTrigger()
        {
            try
            {
                if (WorkerFresh(10, 120)) { return false; }
                TaskRunResult run = RunScheduledTask("OpenPath-RuntimeDependencyApply");
                return run.Success;
            }
            catch
            {
                WriteStageLog("enqueue-trigger-failed", null, "", 0, FieldObject("error", "schtasks"));
                return false;
            }
        }

        // allow-local-runtime-dependency (blocking mode).
        private static JsonObject LocalDependencyAction(JsonObject message, WhitelistSections sections, JsonObject state)
        {
            string mode = GetRuntimeDependencyMode(message);
            if (mode == "invalid")
            {
                JsonObject invalid = new JsonObject();
                invalid.Add("success", false);
                invalid.Add("action", ActionAllowLocal);
                invalid.Add("error", "Unsupported runtime dependency mode");
                return invalid;
            }
            HashSet<string> whitelistSet = BuildWhitelistSet(sections.Whitelist);
            HashSet<string> protectedHosts = BuildProtectedHosts(state);
            HashSet<string> blockedSet = BuildBlockedSubdomainSet(sections.BlockedSubdomains);
            if (mode == "enqueue")
            {
                return LocalDependencyEnqueueAction(message, sections, state, whitelistSet, protectedHosts, blockedSet);
            }
            CandidateValidation candidate = ValidateCandidate(message, sections, state, whitelistSet, protectedHosts, blockedSet, ActionAllowLocal, false);
            if (!candidate.Valid)
            {
                return AddReadinessToResult(candidate.Result, null);
            }
            System.Diagnostics.Stopwatch queueWatch = System.Diagnostics.Stopwatch.StartNew();
            string requestPath = WriteQueueRequest(candidate.AnchorHost, candidate.DependencyHost, candidate.RequestType);
            queueWatch.Stop();
            WriteStageLog("queue-written", new List<string> { candidate.DependencyHost }, "", queueWatch.ElapsedMilliseconds,
                StageFields("anchorHost", candidate.AnchorHost, "requestType", candidate.RequestType, "request", requestPath));

            JsonObject updateResult = UpdateTask(null, new List<string> { candidate.DependencyHost }, requestPath, 14);
            bool updateSuccess = GetBool(updateResult.Get("success"), false);
            WriteStageLog("readiness-observed", new List<string> { candidate.DependencyHost }, "", 0,
                StageFields("ready", updateSuccess ? "true" : "false", "worker", GetBool(updateResult.Get("runtimeDependencyWorker"), false) ? "true" : "false",
                    "updateTriggerMs", GetLong(updateResult.Get("updateTriggerMs"), 0).ToString(CultureInfo.InvariantCulture),
                    "updateWaitMs", GetLong(updateResult.Get("updateWaitMs"), 0).ToString(CultureInfo.InvariantCulture),
                    "updateTaskName", GetString(updateResult.Get("updateTaskName"))));

            JsonObject result = new JsonObject();
            if (!updateSuccess)
            {
                result.Add("success", false);
                result.Add("action", ActionAllowLocal);
                result.Add("anchorHost", candidate.AnchorHost);
                result.Add("dependencyHost", candidate.DependencyHost);
                result.Add("requestType", candidate.RequestType);
                result.Add("queued", true);
                result.Add("runtimeDependencyState", "error");
                result.Add("requestPath", requestPath);
                result.Add("queueWriteMs", (int)queueWatch.ElapsedMilliseconds);
                AddUpdateTimings(result, updateResult);
                result.Add("error", GetString(updateResult.Get("error")));
                return result;
            }
            result.Add("success", true);
            result.Add("action", ActionAllowLocal);
            result.Add("anchorHost", candidate.AnchorHost);
            result.Add("dependencyHost", candidate.DependencyHost);
            result.Add("requestType", candidate.RequestType);
            result.Add("queued", true);
            result.Add("ready", true);
            result.Add("runtimeDependencyState", "ready");
            result.Add("requestPath", requestPath);
            result.Add("queueWriteMs", (int)queueWatch.ElapsedMilliseconds);
            AddUpdateTimings(result, updateResult);
            result.Add("source", SourceFirefoxWebRequestLocal);
            return result;
        }

        private static JsonObject StageFields(params string[] pairs)
        {
            JsonObject fields = new JsonObject();
            for (int index = 0; index + 1 < pairs.Length; index += 2)
            {
                fields.Add(pairs[index], pairs[index + 1]);
            }
            return fields;
        }

        private static void AddUpdateTimings(JsonObject result, JsonObject updateResult)
        {
            result.Add("updateTriggerMs", (int)GetLong(updateResult.Get("updateTriggerMs"), 0));
            result.Add("updateWaitMs", (int)GetLong(updateResult.Get("updateWaitMs"), 0));
            result.Add("updateElapsedMs", (int)GetLong(updateResult.Get("elapsedMs"), 0));
            result.Add("runtimeDependencyFastPath", GetBool(updateResult.Get("runtimeDependencyFastPath"), false));
            result.Add("runtimeDependencyFallback", GetBool(updateResult.Get("runtimeDependencyFallback"), false));
            result.Add("runtimeDependencyWorker", GetBool(updateResult.Get("runtimeDependencyWorker"), false));
            result.Add("updateTaskName", GetString(updateResult.Get("updateTaskName")));
        }

        private static JsonObject LocalDependencyEnqueueAction(JsonObject message, WhitelistSections sections, JsonObject state, HashSet<string> whitelistSet, HashSet<string> protectedHosts, HashSet<string> blockedSet)
        {
            CandidateValidation candidate = ValidateCandidate(message, sections, state, whitelistSet, protectedHosts, blockedSet, ActionAllowLocal, true);
            if (!candidate.Valid)
            {
                return AddReadinessToResult(candidate.Result, null);
            }
            OverlaySnapshot snapshot = ReadOverlaySnapshot();
            JsonObject entryState = EntryState(snapshot, candidate.AnchorHost, candidate.DependencyHost);
            if (GetBool(entryState.Get("ready"), false))
            {
                JsonObject ready = new JsonObject();
                ready.Add("success", true);
                ready.Add("action", ActionAllowLocal);
                ready.Add("anchorHost", candidate.AnchorHost);
                ready.Add("dependencyHost", candidate.DependencyHost);
                ready.Add("requestType", candidate.RequestType);
                ready.Add("queued", false);
                ready.Add("ready", true);
                ready.Add("runtimeDependencyState", "ready");
                ready.Add("mode", "enqueue");
                ready.Add("source", SourceFirefoxWebRequestLocal);
                return ready;
            }
            System.Diagnostics.Stopwatch queueWatch = System.Diagnostics.Stopwatch.StartNew();
            string requestPath = WriteQueueRequest(candidate.AnchorHost, candidate.DependencyHost, candidate.RequestType);
            queueWatch.Stop();
            bool workerTriggered = SendEnqueueTrigger();
            WriteStageLog("queue-written", new List<string> { candidate.DependencyHost }, "", queueWatch.ElapsedMilliseconds,
                StageFields("anchorHost", candidate.AnchorHost, "requestType", candidate.RequestType, "request", requestPath,
                    "mode", "enqueue", "workerTriggered", workerTriggered ? "true" : "false"));
            JsonObject result = new JsonObject();
            result.Add("success", true);
            result.Add("action", ActionAllowLocal);
            result.Add("anchorHost", candidate.AnchorHost);
            result.Add("dependencyHost", candidate.DependencyHost);
            result.Add("requestType", candidate.RequestType);
            result.Add("queued", true);
            result.Add("ready", false);
            result.Add("runtimeDependencyState", "pending");
            result.Add("mode", "enqueue");
            result.Add("requestPath", requestPath);
            result.Add("queueWriteMs", (int)queueWatch.ElapsedMilliseconds);
            result.Add("workerTriggered", workerTriggered);
            result.Add("source", SourceFirefoxWebRequestLocal);
            return result;
        }

        // allow-local-runtime-dependency-batch.
        private static JsonObject LocalDependencyBatchAction(JsonObject message, WhitelistSections sections, JsonObject state)
        {
            string mode = GetRuntimeDependencyMode(message);
            if (mode == "invalid")
            {
                JsonObject invalid = new JsonObject();
                invalid.Add("success", false);
                invalid.Add("action", ActionAllowLocalBatch);
                invalid.Add("error", "Unsupported runtime dependency mode");
                return invalid;
            }
            List<JsonObject> entries = GetBatchEntries(message);
            if (entries.Count == 0)
            {
                JsonObject empty = new JsonObject();
                empty.Add("success", false);
                empty.Add("action", ActionAllowLocalBatch);
                empty.Add("error", "Invalid runtime dependency batch payload");
                empty.Add("results", new List<object>());
                return empty;
            }
            HashSet<string> whitelistSet = BuildWhitelistSet(sections.Whitelist);
            HashSet<string> protectedHosts = BuildProtectedHosts(state);
            HashSet<string> blockedSet = BuildBlockedSubdomainSet(sections.BlockedSubdomains);
            if (mode == "enqueue")
            {
                return LocalDependencyBatchEnqueueAction(message, entries, sections, state, whitelistSet, protectedHosts, blockedSet);
            }
            List<object> results = new List<object>();
            List<JsonObject> queuedResults = new List<JsonObject>();
            List<string> queuedDependencyHosts = new List<string>();
            int count = 0;
            foreach (JsonObject entry in entries)
            {
                if (count >= BatchMaxEntries) { break; }
                count++;
                CandidateValidation candidate = ValidateCandidate(entry, sections, state, whitelistSet, protectedHosts, blockedSet, ActionAllowLocal, false);
                if (!candidate.Valid)
                {
                    results.Add(AddReadinessToResult(candidate.Result, null));
                    continue;
                }
                System.Diagnostics.Stopwatch queueWatch = System.Diagnostics.Stopwatch.StartNew();
                string requestPath = WriteQueueRequest(candidate.AnchorHost, candidate.DependencyHost, candidate.RequestType);
                queueWatch.Stop();
                JsonObject result = new JsonObject();
                result.Add("success", true);
                result.Add("action", ActionAllowLocal);
                result.Add("anchorHost", candidate.AnchorHost);
                result.Add("dependencyHost", candidate.DependencyHost);
                result.Add("requestType", candidate.RequestType);
                result.Add("queued", true);
                result.Add("requestPath", requestPath);
                result.Add("queueWriteMs", (int)queueWatch.ElapsedMilliseconds);
                result.Add("source", SourceFirefoxWebRequestLocal);
                results.Add(result);
                queuedResults.Add(result);
                queuedDependencyHosts.Add(candidate.DependencyHost);
            }
            if (entries.Count > BatchMaxEntries)
            {
                results.Add(CandidateFailure("Runtime dependency batch limit exceeded", ActionAllowLocal));
            }
            if (queuedDependencyHosts.Count > 0)
            {
                List<string> uniqueHosts = new List<string>();
                foreach (string host in queuedDependencyHosts) { if (!uniqueHosts.Contains(host)) { uniqueHosts.Add(host); } }
                WriteStageLog("queue-written", uniqueHosts, "", 0, StageFields("count", queuedResults.Count.ToString(CultureInfo.InvariantCulture)));
                JsonObject updateResult = UpdateTask(null, uniqueHosts, "", 14);
                bool updateSuccess = GetBool(updateResult.Get("success"), false);
                WriteStageLog("readiness-observed", uniqueHosts, "", 0,
                    StageFields("ready", updateSuccess ? "true" : "false", "worker", GetBool(updateResult.Get("runtimeDependencyWorker"), false) ? "true" : "false",
                        "updateTriggerMs", GetLong(updateResult.Get("updateTriggerMs"), 0).ToString(CultureInfo.InvariantCulture),
                        "updateWaitMs", GetLong(updateResult.Get("updateWaitMs"), 0).ToString(CultureInfo.InvariantCulture),
                        "updateTaskName", GetString(updateResult.Get("updateTaskName"))));
                foreach (JsonObject result in queuedResults)
                {
                    if (!updateSuccess)
                    {
                        result.Set("success", false);
                        result.Set("runtimeDependencyState", "error");
                        result.Set("error", GetString(updateResult.Get("error")));
                    }
                    else
                    {
                        result.Set("ready", true);
                        result.Set("runtimeDependencyState", "ready");
                    }
                    result.Set("updateTriggerMs", (int)GetLong(updateResult.Get("updateTriggerMs"), 0));
                    result.Set("updateWaitMs", (int)GetLong(updateResult.Get("updateWaitMs"), 0));
                    result.Set("updateElapsedMs", (int)GetLong(updateResult.Get("elapsedMs"), 0));
                    result.Set("runtimeDependencyFastPath", GetBool(updateResult.Get("runtimeDependencyFastPath"), false));
                    result.Set("runtimeDependencyFallback", GetBool(updateResult.Get("runtimeDependencyFallback"), false));
                    result.Set("runtimeDependencyWorker", GetBool(updateResult.Get("runtimeDependencyWorker"), false));
                    result.Set("updateTaskName", GetString(updateResult.Get("updateTaskName")));
                }
            }
            bool anyFailed = false;
            foreach (object item in results)
            {
                JsonObject result = item as JsonObject;
                if (result != null && !GetBool(result.Get("success"), false)) { anyFailed = true; }
            }
            JsonObject response = new JsonObject();
            response.Add("success", !anyFailed);
            response.Add("action", ActionAllowLocalBatch);
            response.Add("count", results.Count);
            response.Add("queuedCount", queuedResults.Count);
            response.Add("results", results);
            return response;
        }

        private static JsonObject LocalDependencyBatchEnqueueAction(JsonObject message, List<JsonObject> entries, WhitelistSections sections, JsonObject state, HashSet<string> whitelistSet, HashSet<string> protectedHosts, HashSet<string> blockedSet)
        {
            List<object> results = new List<object>();
            List<JsonObject> queuedResults = new List<JsonObject>();
            OverlaySnapshot snapshot = null;
            Dictionary<string, JsonObject> pairStateCache = new Dictionary<string, JsonObject>(StringComparer.OrdinalIgnoreCase);
            int count = 0;
            foreach (JsonObject entry in entries)
            {
                if (count >= BatchMaxEntries) { break; }
                count++;
                CandidateValidation candidate = ValidateCandidate(entry, sections, state, whitelistSet, protectedHosts, blockedSet, ActionAllowLocal, true);
                if (!candidate.Valid)
                {
                    results.Add(AddReadinessToResult(candidate.Result, snapshot));
                    continue;
                }
                if (snapshot == null) { snapshot = ReadOverlaySnapshot(); }
                string pairKey = candidate.AnchorHost + "|" + candidate.DependencyHost;
                JsonObject entryState;
                if (!pairStateCache.ContainsKey(pairKey))
                {
                    entryState = EntryState(snapshot, candidate.AnchorHost, candidate.DependencyHost);
                    pairStateCache[pairKey] = entryState;
                }
                else { entryState = pairStateCache[pairKey]; }
                if (GetBool(entryState.Get("ready"), false))
                {
                    JsonObject ready = new JsonObject();
                    ready.Add("success", true);
                    ready.Add("action", ActionAllowLocal);
                    ready.Add("anchorHost", candidate.AnchorHost);
                    ready.Add("dependencyHost", candidate.DependencyHost);
                    ready.Add("requestType", candidate.RequestType);
                    ready.Add("queued", false);
                    ready.Add("ready", true);
                    ready.Add("runtimeDependencyState", "ready");
                    ready.Add("source", SourceFirefoxWebRequestLocal);
                    results.Add(ready);
                    continue;
                }
                System.Diagnostics.Stopwatch queueWatch = System.Diagnostics.Stopwatch.StartNew();
                string requestPath = WriteQueueRequest(candidate.AnchorHost, candidate.DependencyHost, candidate.RequestType);
                queueWatch.Stop();
                JsonObject result = new JsonObject();
                result.Add("success", true);
                result.Add("action", ActionAllowLocal);
                result.Add("anchorHost", candidate.AnchorHost);
                result.Add("dependencyHost", candidate.DependencyHost);
                result.Add("requestType", candidate.RequestType);
                result.Add("queued", true);
                result.Add("ready", false);
                result.Add("runtimeDependencyState", "pending");
                result.Add("requestPath", requestPath);
                result.Add("queueWriteMs", (int)queueWatch.ElapsedMilliseconds);
                result.Add("source", SourceFirefoxWebRequestLocal);
                results.Add(result);
                queuedResults.Add(result);
            }
            if (entries.Count > BatchMaxEntries)
            {
                results.Add(CandidateFailure("Runtime dependency batch limit exceeded", ActionAllowLocal));
            }
            bool workerTriggered = false;
            if (queuedResults.Count > 0)
            {
                workerTriggered = SendEnqueueTrigger();
                List<string> hosts = new List<string>();
                long totalQueueMs = 0;
                foreach (JsonObject result in queuedResults)
                {
                    result.Set("workerTriggered", workerTriggered);
                    hosts.Add(GetString(result.Get("dependencyHost")));
                    totalQueueMs += GetLong(result.Get("queueWriteMs"), 0);
                }
                WriteStageLog("queue-written", hosts, "", totalQueueMs, StageFields("count", queuedResults.Count.ToString(CultureInfo.InvariantCulture), "mode", "enqueue", "workerTriggered", workerTriggered ? "true" : "false"));
            }
            bool anyFailed = false;
            foreach (object item in results)
            {
                JsonObject result = item as JsonObject;
                if (result != null && !GetBool(result.Get("success"), false)) { anyFailed = true; }
            }
            JsonObject response = new JsonObject();
            response.Add("success", !anyFailed);
            response.Add("action", ActionAllowLocalBatch);
            response.Add("mode", "enqueue");
            response.Add("count", results.Count);
            response.Add("queuedCount", queuedResults.Count);
            response.Add("workerTriggered", workerTriggered);
            response.Add("results", results);
            return response;
        }

        private static List<JsonObject> GetBatchEntries(JsonObject message)
        {
            List<JsonObject> entries = new List<JsonObject>();
            List<object> raw = AsArray(message == null ? null : message.Get("entries"));
            if (raw == null) { return entries; }
            foreach (object item in raw)
            {
                JsonObject entry = item as JsonObject;
                if (entry != null) { entries.Add(entry); }
            }
            return entries;
        }

        // check-local-runtime-dependency.
        private static JsonObject CheckLocalDependencyAction(JsonObject message)
        {
            if (HasSensitiveField(message))
            {
                JsonObject sensitive = new JsonObject();
                sensitive.Add("success", false);
                sensitive.Add("action", ActionCheckLocal);
                sensitive.Add("error", "Sensitive fields are not accepted");
                return sensitive;
            }
            List<JsonObject> entries = GetBatchEntries(message);
            if (entries.Count > 0)
            {
                OverlaySnapshot snapshot = ReadOverlaySnapshot();
                List<object> results = new List<object>();
                int count = 0;
                foreach (JsonObject entry in entries)
                {
                    if (count >= BatchMaxEntries) { break; }
                    count++;
                    string anchorHost = NormalizeHost(GetString(entry.Get("anchorHost")));
                    string dependencyHost = NormalizeHost(GetString(entry.Get("dependencyHost")));
                    if (anchorHost.Length == 0 || dependencyHost.Length == 0)
                    {
                        JsonObject invalid = new JsonObject();
                        invalid.Add("success", false);
                        invalid.Add("action", ActionCheckLocal);
                        invalid.Add("error", "Invalid runtime dependency payload");
                        results.Add(invalid);
                        continue;
                    }
                    JsonObject entryState = EntryState(snapshot, anchorHost, dependencyHost);
                    JsonObject result = new JsonObject();
                    result.Add("success", true);
                    result.Add("action", ActionCheckLocal);
                    result.Add("anchorHost", anchorHost);
                    result.Add("dependencyHost", dependencyHost);
                    result.Add("ready", GetBool(entryState.Get("ready"), false));
                    result.Add("runtimeDependencyState", GetString(entryState.Get("runtimeDependencyState")));
                    string expiresAt = GetString(entryState.Get("expiresAt"));
                    if (expiresAt.Length > 0) { result.Add("expiresAt", expiresAt); }
                    results.Add(result);
                }
                if (entries.Count > BatchMaxEntries)
                {
                    JsonObject limit = new JsonObject();
                    limit.Add("success", false);
                    limit.Add("action", ActionCheckLocal);
                    limit.Add("error", "Runtime dependency batch limit exceeded");
                    results.Add(limit);
                }
                bool anyFailed = false;
                foreach (object item in results)
                {
                    JsonObject result = item as JsonObject;
                    if (result != null && !GetBool(result.Get("success"), false)) { anyFailed = true; }
                }
                JsonObject response = new JsonObject();
                response.Add("success", !anyFailed);
                response.Add("action", ActionCheckLocal);
                response.Add("count", results.Count);
                response.Add("results", results);
                return response;
            }
            string singleAnchor = NormalizeHost(GetString(message.Get("anchorHost")));
            string singleDependency = NormalizeHost(GetString(message.Get("dependencyHost")));
            if (singleAnchor.Length == 0 || singleDependency.Length == 0)
            {
                JsonObject invalid = new JsonObject();
                invalid.Add("success", false);
                invalid.Add("action", ActionCheckLocal);
                invalid.Add("error", "Invalid runtime dependency payload");
                return invalid;
            }
            OverlaySnapshot snapshotSingle = ReadOverlaySnapshot();
            JsonObject stateSingle = EntryState(snapshotSingle, singleAnchor, singleDependency);
            JsonObject single = new JsonObject();
            single.Add("success", true);
            single.Add("action", ActionCheckLocal);
            single.Add("anchorHost", singleAnchor);
            single.Add("dependencyHost", singleDependency);
            single.Add("ready", GetBool(stateSingle.Get("ready"), false));
            single.Add("runtimeDependencyState", GetString(stateSingle.Get("runtimeDependencyState")));
            string expires = GetString(stateSingle.Get("expiresAt"));
            if (expires.Length > 0) { single.Add("expiresAt", expires); }
            return single;
        }
    }
}
// Part 5a: captive portal helpers (marker, observation, probe, signals).

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        private sealed class PortalProbeCacheEntry
        {
            public DateTime ProbedAtUtc;
            public string Signal;
        }

        private static readonly Dictionary<string, PortalProbeCacheEntry> PortalProbeCache = new Dictionary<string, PortalProbeCacheEntry>(StringComparer.OrdinalIgnoreCase);

        private static string GetMarkerPath()
        {
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "captive-portal-active.json");
        }

        private static string GetObservationPath()
        {
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "captive-portal-observation.json");
        }

        private static string GetRecoveryQueuePath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_CAPTIVE_PORTAL_RECOVERY_QUEUE_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "captive-portal-recovery-queue");
        }

        private static string GetRecoveryResultPath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_CAPTIVE_PORTAL_RECOVERY_RESULT_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "captive-portal-recovery-result");
        }

        private static string GetRecoveryProgressPath()
        {
            string overridePath = Environment.GetEnvironmentVariable("OPENPATH_CAPTIVE_PORTAL_RECOVERY_PROGRESS_PATH");
            if (!string.IsNullOrEmpty(overridePath)) { return overridePath; }
            return Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "captive-portal-recovery-progress");
        }

        // Captive portal domains declared in the agent config. The PowerShell
        // reference reads them through Common (loaded lazily with the portal
        // module), so the compiled host reads the same config field directly.
        private static List<string> GetConfiguredPortalDomains()
        {
            List<string> domains = new List<string>();
            try
            {
                string configPath = Path.Combine(Path.Combine(GetOpenPathRoot(), "data"), "config.json");
                if (!File.Exists(configPath)) { return domains; }
                JsonObject config = JsonParse(ReadAllTextShared(configPath)) as JsonObject;
                if (config == null) { return domains; }
                List<object> entries = AsArray(config.Get("captivePortalDomains"));
                if (entries == null) { return domains; }
                foreach (object item in entries)
                {
                    if (item == null) { continue; }
                    string raw = GetString(item).Trim();
                    if (raw.Length == 0) { continue; }
                    if (System.Text.RegularExpressions.Regex.IsMatch(raw, "^[a-z][a-z0-9+.-]*://")) { continue; }
                    if (System.Text.RegularExpressions.Regex.IsMatch(raw, "[/?#@]")) { continue; }
                    string hostName = raw.TrimEnd('.').ToLowerInvariant();
                    if (RejectDynamicPortalHost(hostName)) { continue; }
                    if (!domains.Contains(hostName)) { domains.Add(hostName); }
                }
            }
            catch { }
            return domains;
        }

        private static bool RejectDynamicPortalHost(string hostName)
        {
            if (string.IsNullOrEmpty(hostName)) { return true; }
            if (hostName.StartsWith("*.") || hostName.StartsWith(".")) { return true; }
            if (System.Text.RegularExpressions.Regex.IsMatch(hostName, "^\\d{1,3}(?:\\.\\d{1,3}){3}$")) { return true; }
            if (System.Text.RegularExpressions.Regex.IsMatch(hostName, "^\\[[0-9a-f:]+\\]$")) { return true; }
            if (hostName.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) { return true; }
            if (hostName.IndexOf('.') < 0) { return true; }
            if (hostName.Length < 4 || hostName.Length > 253) { return true; }
            if (!System.Text.RegularExpressions.Regex.IsMatch(hostName, "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)+$")) { return true; }
            return false;
        }

        private static List<string> GetPortalEffectiveHosts(IEnumerable<string> hosts)
        {
            List<string> unique = new List<string>();
            if (hosts == null) { return unique; }
            foreach (string item in hosts)
            {
                string normalized = GetString(item).Trim().TrimEnd('.').ToLowerInvariant();
                if (normalized.Length == 0) { continue; }
                if (!System.Text.RegularExpressions.Regex.IsMatch(normalized, "^[a-z0-9.-]+$")) { continue; }
                if (normalized.StartsWith(".") || normalized.EndsWith(".") || normalized.IndexOf("..", StringComparison.Ordinal) >= 0) { continue; }
                if (!unique.Contains(normalized)) { unique.Add(normalized); }
            }
            return unique;
        }

        private static bool ConfiguredPortalDomainsApplied(List<string> allowedHosts, List<string> configuredDomains)
        {
            foreach (string configured in configuredDomains)
            {
                bool found = false;
                foreach (string allowed in allowedHosts) { if (string.Equals(allowed, configured, StringComparison.OrdinalIgnoreCase)) { found = true; break; } }
                if (!found) { return false; }
            }
            return true;
        }

        private static JsonObject ReadPortalMarker()
        {
            try
            {
                string markerPath = GetMarkerPath();
                if (!File.Exists(markerPath)) { return null; }
                JsonObject payload = JsonParse(ReadAllTextShared(markerPath)) as JsonObject;
                if (payload == null) { return null; }
                if (payload.ContainsKey("active") && !GetBool(payload.Get("active"), true)) { return null; }
                if (!payload.ContainsKey("expiresAt") || payload.Get("expiresAt") == null) { return null; }
                DateTime expiresAt;
                if (!DateTime.TryParse(GetString(payload.Get("expiresAt")), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out expiresAt)) { return null; }
                if (DateTime.UtcNow >= expiresAt.ToUniversalTime()) { return null; }
                payload.Set("Path", markerPath);
                payload.Set("LastWriteTimeUtc", File.GetLastWriteTimeUtc(markerPath).ToString("o", CultureInfo.InvariantCulture));
                payload.Set("_lastWriteTimeUtcTicks", File.GetLastWriteTimeUtc(markerPath).Ticks);
                return payload;
            }
            catch { return null; }
        }

        private static JsonObject ReadPortalObservation()
        {
            try
            {
                string observationPath = GetObservationPath();
                if (!File.Exists(observationPath)) { return null; }
                return JsonParse(ReadAllTextShared(observationPath)) as JsonObject;
            }
            catch { return null; }
        }

        private static bool ObservationRecent(JsonObject observation, int maxAgeSeconds)
        {
            if (observation == null) { return false; }
            if (GetString(observation.Get("detectedState")) != "Portal") { return false; }
            foreach (string propertyName in new string[] { "updatedAt", "observedAt", "detectedAt" })
            {
                object raw = observation.Get(propertyName);
                if (raw == null) { continue; }
                DateTime timestamp;
                if (DateTime.TryParse(GetString(raw), CultureInfo.InvariantCulture, DateTimeStyles.RoundtripKind, out timestamp))
                {
                    return (DateTime.UtcNow - timestamp.ToUniversalTime()).TotalSeconds <= Math.Max(1, maxAgeSeconds);
                }
            }
            return false;
        }

        private static bool PotentialCaptiveNetwork()
        {
            try
            {
                bool up = false;
                foreach (System.Net.NetworkInformation.NetworkInterface adapter in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces())
                {
                    if (adapter.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up) { continue; }
                    if (adapter.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) { continue; }
                    up = true;
                    foreach (System.Net.NetworkInformation.GatewayIPAddressInformation gateway in adapter.GetIPProperties().GatewayAddresses)
                    {
                        if (gateway.Address == null) { continue; }
                        string nextHop = gateway.Address.ToString();
                        if (nextHop == "0.0.0.0" || nextHop.StartsWith("127.")) { continue; }
                        return true;
                    }
                }
                return false;
            }
            catch { return false; }
        }

        // Test-OpenPathCaptivePortalState: three probe endpoints, no redirects.
        private static string TestPortalState(int timeoutSeconds)
        {
            string[] urls = new string[] { "http://www.msftconnecttest.com/connecttest.txt", "http://detectportal.firefox.com/success.txt", "http://clients3.google.com/generate_204" };
            object[] expectedStatus = new object[] { 200, 200, 204 };
            string[] expectedBody = new string[] { "Microsoft Connect Test", "success", "" };
            int total = urls.Length;
            int success = 0;
            int transportFail = 0;
            for (int index = 0; index < urls.Length; index++)
            {
                int statusCode = 0;
                string content = "";
                try
                {
                    HttpWebRequest request = (HttpWebRequest)WebRequest.Create(urls[index]);
                    request.AllowAutoRedirect = false;
                    request.Timeout = Math.Max(1, timeoutSeconds) * 1000;
                    request.Method = "GET";
                    using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
                    {
                        statusCode = (int)response.StatusCode;
                        using (StreamReader reader = new StreamReader(response.GetResponseStream()))
                        {
                            content = reader.ReadToEnd();
                        }
                    }
                }
                catch (WebException exception)
                {
                    if (exception.Response != null)
                    {
                        try { statusCode = (int)((HttpWebResponse)exception.Response).StatusCode; }
                        catch { statusCode = 0; }
                    }
                    if (statusCode == 0) { transportFail++; }
                    continue;
                }
                catch { transportFail++; continue; }

                content = content.Trim();
                if (statusCode == (int)expectedStatus[index])
                {
                    if (expectedBody[index].Length == 0 || content == expectedBody[index]) { success++; }
                }
            }
            if (total <= 0) { return "NoNetwork"; }
            if (transportFail >= total) { return PotentialCaptiveNetwork() ? "Portal" : "NoNetwork"; }
            int threshold = (int)Math.Floor((double)total / 2) + 1;
            return success >= threshold ? "Authenticated" : "Portal";
        }

        private static string PortalSyncProbe(string domain, int cooldownSeconds)
        {
            string cacheKey = domain.Trim().ToLowerInvariant();
            DateTime now = DateTime.UtcNow;
            PortalProbeCacheEntry cached;
            if (PortalProbeCache.TryGetValue(cacheKey, out cached))
            {
                if (cached != null && (now - cached.ProbedAtUtc).TotalSeconds < Math.Max(1, cooldownSeconds)) { return cached.Signal; }
            }
            string signal = "none";
            try { if (TestPortalState(2) == "Portal") { signal = "sync-probe"; } }
            catch { signal = "none"; }
            PortalProbeCacheEntry entry = new PortalProbeCacheEntry();
            entry.ProbedAtUtc = now;
            entry.Signal = signal;
            PortalProbeCache[cacheKey] = entry;
            return signal;
        }

        private static bool RecoverablePortalError(string errorName)
        {
            return errorName == "NS_ERROR_UNKNOWN_HOST" || errorName == "NS_ERROR_CONNECTION_REFUSED" || errorName == "NS_ERROR_NET_TIMEOUT";
        }

        private static string GetPortalRecoverySignal(string domain, JsonObject message)
        {
            if (ReadPortalMarker() != null) { return "marker"; }
            if (ObservationRecent(ReadPortalObservation(), 120)) { return "observation"; }
            if (GetString(message.Get("portalState")) == "locked_portal") { return "firefox-locked"; }
            string errorName = GetString(message.Get("error"));
            string source = GetString(message.Get("source"));
            if (source == "blocked-screen-navigation" && RecoverablePortalError(errorName))
            {
                return PortalSyncProbe(domain, 15);
            }
            return "none";
        }

        // Marker summary: only the fields the recovery response consumes.
        private static JsonObject PortalMarkerSummary(JsonObject marker, string triggerHost)
        {
            List<string> allowedHosts = new List<string>();
            List<object> allowedRaw = AsArray(marker.Get("allowedHosts"));
            if (allowedRaw != null) { foreach (object item in allowedRaw) { string text = GetString(item).Trim(); if (text.Length > 0) { allowedHosts.Add(text); } } }
            List<string> bootstrapHosts = StringList(marker.Get("bootstrapHosts"));
            List<string> redirectHosts = StringList(marker.Get("redirectHosts"));
            List<string> resourceHosts = StringList(marker.Get("resourceHosts"));
            List<string> observedRuntimeHosts = StringList(marker.Get("observedRuntimeHosts"));
            List<string> pendingRuntimeHosts = StringList(marker.Get("pendingRuntimeHosts"));
            List<string> configuredDomains = GetConfiguredPortalDomains();
            string mode = GetString(marker.Get("mode"));
            string fallbackMode = GetString(marker.Get("fallbackMode"));
            if (fallbackMode.Length == 0) { fallbackMode = mode == "passthrough" ? "passthrough" : "none"; }
            bool markerLimitedModeReady = GetBool(marker.Get("limitedModeReady"), false);
            bool recoveryHostsApplied = mode == "limited" && allowedHosts.Count > 0;
            bool configuredApplied = ConfiguredPortalDomainsApplied(allowedHosts, configuredDomains);
            List<string> effectiveHosts = GetPortalEffectiveHosts(Concat(allowedHosts, bootstrapHosts, redirectHosts, resourceHosts, observedRuntimeHosts, configuredDomains));
            List<string> declaredRecoveryHosts = GetPortalEffectiveHosts(Concat(new List<string> { triggerHost }, configuredDomains));
            if (declaredRecoveryHosts.Count <= 0) { declaredRecoveryHosts = allowedHosts; }
            bool declaredApplied = declaredRecoveryHosts.Count > 0;
            foreach (string hostName in declaredRecoveryHosts)
            {
                bool found = false;
                foreach (string allowed in allowedHosts) { if (string.Equals(allowed, hostName, StringComparison.OrdinalIgnoreCase)) { found = true; break; } }
                if (!found) { declaredApplied = false; break; }
            }
            bool limitedModeReady = mode == "limited" && recoveryHostsApplied && markerLimitedModeReady && declaredApplied && configuredApplied;
            bool recentSuccessEligible = limitedModeReady;
            if (recentSuccessEligible && triggerHost.Length > 0)
            {
                bool found = false;
                foreach (string allowed in allowedHosts) { if (string.Equals(allowed, triggerHost, StringComparison.OrdinalIgnoreCase)) { found = true; break; } }
                recentSuccessEligible = found;
            }
            JsonObject summary = new JsonObject();
            summary.Add("activeMarkerMode", mode);
            summary.Add("allowedHosts", allowedHosts);
            summary.Add("effectiveExactHosts", effectiveHosts);
            summary.Add("configuredCaptivePortalDomains", configuredDomains);
            summary.Add("configuredCaptivePortalDomainsApplied", configuredApplied);
            summary.Add("bootstrapHosts", bootstrapHosts);
            summary.Add("redirectHosts", redirectHosts);
            summary.Add("resourceHosts", resourceHosts);
            summary.Add("observedRuntimeHosts", observedRuntimeHosts);
            summary.Add("pendingRuntimeHosts", pendingRuntimeHosts);
            summary.Add("discoveryTruncated", GetBool(marker.Get("discoveryTruncated"), false));
            summary.Add("fallbackMode", fallbackMode);
            summary.Add("limitedModeReady", limitedModeReady);
            summary.Add("recoveryHostsApplied", recoveryHostsApplied);
            summary.Add("recentSuccessEligible", recentSuccessEligible);
            return summary;
        }

        private static List<string> StringList(object value)
        {
            List<string> result = new List<string>();
            List<object> raw = AsArray(value);
            if (raw == null) { return result; }
            foreach (object item in raw)
            {
                string text = GetString(item).Trim();
                if (text.Length > 0) { result.Add(text); }
            }
            return result;
        }

        private static List<string> Concat(params List<string>[] lists)
        {
            List<string> result = new List<string>();
            foreach (List<string> list in lists) { if (list != null) { result.AddRange(list); } }
            return result;
        }

        private static List<string> GetRecoveryHosts(string triggerHost, object portalRecoveryHosts)
        {
            List<string> hosts = new List<string>();
            List<string> candidates = new List<string>();
            if (!string.IsNullOrEmpty(triggerHost)) { candidates.Add(triggerHost); }
            List<object> raw = AsArray(portalRecoveryHosts);
            if (raw != null) { foreach (object item in raw) { if (item is string) { candidates.Add((string)item); } } }
            foreach (string candidate in candidates)
            {
                string hostName = NormalizeHost(candidate);
                if (hostName.Length == 0) { continue; }
                if (System.Text.RegularExpressions.Regex.IsMatch(hostName, "^\\d{1,3}(?:\\.\\d{1,3}){3}$") || System.Text.RegularExpressions.Regex.IsMatch(hostName, "^\\[[0-9a-f:]+\\]$")) { continue; }
                if (hostName.EndsWith(".local", StringComparison.OrdinalIgnoreCase)) { continue; }
                if (hostName.IndexOf('.') < 0) { continue; }
                if (hosts.Contains(hostName)) { continue; }
                if (hosts.Count >= 16) { break; }
                hosts.Add(hostName);
            }
            return hosts;
        }
    }
}
// Part 5b: captive portal recovery action, extension diagnostics, dispatch, main.

namespace OpenPathNativeHost
{
    internal static partial class Program
    {
        private sealed class RecentPortalSuccess
        {
            public string Source = "";
            public string RequestId = "";
            public string State = "";
            public string ActiveMarkerMode = "";
            public List<string> AllowedHosts = new List<string>();
            public List<string> ConfiguredDomains = new List<string>();
            public List<string> EffectiveExactHosts = new List<string>();
            public bool LimitedModeReady;
            public bool RecentSuccessEligible;
            public string FallbackMode = "none";
            public JsonObject Payload;
            public List<string> PortalRecoveryHosts = new List<string>();
            public List<string> BootstrapHosts = new List<string>();
            public List<string> RedirectHosts = new List<string>();
            public List<string> ResourceHosts = new List<string>();
            public List<string> ObservedRuntimeHosts = new List<string>();
            public List<string> PendingRuntimeHosts = new List<string>();
            public bool DiscoveryTruncated;
            public bool ConfiguredApplied;
            public bool RecoveryHostsApplied;
        }

        private static RecentPortalSuccess GetRecentPortalSuccess()
        {
            JsonObject marker = ReadPortalMarker();
            if (marker != null && marker.ContainsKey("_lastWriteTimeUtcTicks"))
            {
                double ageSeconds = (DateTime.UtcNow - new DateTime((long)GetLong(marker.Get("_lastWriteTimeUtcTicks"), 0), DateTimeKind.Utc)).TotalSeconds;
                if (ageSeconds <= 30)
                {
                    JsonObject summary = PortalMarkerSummary(marker, "");
                    RecentPortalSuccess success = new RecentPortalSuccess();
                    success.Source = "active-marker";
                    success.RequestId = "";
                    success.State = marker.ContainsKey("state") && GetString(marker.Get("state")).Length > 0 ? GetString(marker.Get("state")) : "Portal";
                    success.ActiveMarkerMode = GetString(summary.Get("activeMarkerMode"));
                    success.AllowedHosts = StringList(summary.Get("allowedHosts"));
                    success.ConfiguredDomains = StringList(summary.Get("configuredCaptivePortalDomains"));
                    success.EffectiveExactHosts = StringList(summary.Get("effectiveExactHosts"));
                    success.LimitedModeReady = GetBool(summary.Get("limitedModeReady"), false);
                    success.RecentSuccessEligible = GetBool(summary.Get("recentSuccessEligible"), false);
                    // Derived flags the response reuses: the marker file has no
                    // recoveryHostsApplied/configured... fields of its own.
                    success.ConfiguredApplied = GetBool(summary.Get("configuredCaptivePortalDomainsApplied"), false);
                    success.RecoveryHostsApplied = GetBool(summary.Get("recoveryHostsApplied"), false);
                    success.FallbackMode = GetString(summary.Get("fallbackMode"));
                    success.Payload = marker;
                    success.BootstrapHosts = StringList(summary.Get("bootstrapHosts"));
                    success.RedirectHosts = StringList(summary.Get("redirectHosts"));
                    return success;
                }
            }
            string resultRoot = GetRecoveryResultPath();
            if (!Directory.Exists(resultRoot)) { return null; }
            DateTime cutoff = DateTime.UtcNow.AddSeconds(-30);
            string bestPath = null;
            DateTime bestWrite = DateTime.MinValue;
            foreach (string file in Directory.GetFiles(resultRoot, "*.json"))
            {
                DateTime write = File.GetLastWriteTimeUtc(file);
                if (write < cutoff) { continue; }
                if (bestPath == null || write > bestWrite) { bestPath = file; bestWrite = write; }
            }
            if (bestPath == null) { return null; }
            try
            {
                JsonObject payload = JsonParse(ReadAllTextShared(bestPath)) as JsonObject;
                if (payload == null) { return null; }
                string state = payload.ContainsKey("state") && GetString(payload.Get("state")).Length > 0 ? GetString(payload.Get("state")) : "Unknown";
                bool portalModeActive = GetBool(payload.Get("portalModeActive"), false);
                bool successPayload = GetBool(payload.Get("success"), false);
                if (!(successPayload && (portalModeActive || state == "Portal" || state == "RecentSuccess"))) { return null; }
                RecentPortalSuccess success = new RecentPortalSuccess();
                success.Source = "result";
                success.RequestId = GetString(payload.Get("requestId"));
                success.State = state;
                success.ActiveMarkerMode = GetString(payload.Get("activeMarkerMode"));
                success.AllowedHosts = StringList(payload.Get("allowedHosts"));
                success.ConfiguredDomains = payload.ContainsKey("configuredCaptivePortalDomains") ? StringList(payload.Get("configuredCaptivePortalDomains")) : GetConfiguredPortalDomains();
                if (payload.ContainsKey("effectiveExactHosts")) { success.EffectiveExactHosts = StringList(payload.Get("effectiveExactHosts")); }
                else { success.EffectiveExactHosts = GetPortalEffectiveHosts(Concat(success.AllowedHosts, success.ConfiguredDomains)); }
                success.ConfiguredApplied = payload.ContainsKey("configuredCaptivePortalDomainsApplied") ? GetBool(payload.Get("configuredCaptivePortalDomainsApplied"), false) : ConfiguredPortalDomainsApplied(success.AllowedHosts, success.ConfiguredDomains);
                success.BootstrapHosts = StringList(payload.Get("bootstrapHosts"));
                success.RedirectHosts = StringList(payload.Get("redirectHosts"));
                success.ResourceHosts = StringList(payload.Get("resourceHosts"));
                success.ObservedRuntimeHosts = StringList(payload.Get("observedRuntimeHosts"));
                success.PendingRuntimeHosts = StringList(payload.Get("pendingRuntimeHosts"));
                success.DiscoveryTruncated = GetBool(payload.Get("discoveryTruncated"), false);
                success.FallbackMode = payload.ContainsKey("fallbackMode") && GetString(payload.Get("fallbackMode")).Length > 0 ? GetString(payload.Get("fallbackMode")) : "none";
                success.LimitedModeReady = GetBool(payload.Get("limitedModeReady"), false);
                success.RecoveryHostsApplied = GetBool(payload.Get("recoveryHostsApplied"), false);
                success.RecentSuccessEligible = GetBool(payload.Get("recentSuccessEligible"), false);
                success.Payload = payload;
                return success;
            }
            catch { return null; }
        }

        private static bool TestRecentSuccessEligible(RecentPortalSuccess recentSuccess, string triggerHost)
        {
            if (recentSuccess == null) { return false; }
            if (!recentSuccess.RecentSuccessEligible) { return false; }
            if (!recentSuccess.LimitedModeReady) { return false; }
            if (recentSuccess.FallbackMode == "passthrough") { return false; }
            if (recentSuccess.ActiveMarkerMode == "passthrough") { return false; }
            if (triggerHost.Length > 0)
            {
                if (recentSuccess.AllowedHosts.Count <= 0) { return false; }
                bool found = false;
                foreach (string host in recentSuccess.AllowedHosts) { if (string.Equals(host, triggerHost, StringComparison.OrdinalIgnoreCase)) { found = true; break; } }
                if (!found) { return false; }
            }
            List<string> configured = GetConfiguredPortalDomains();
            if (configured.Count > 0 && !ConfiguredPortalDomainsApplied(recentSuccess.AllowedHosts, configured)) { return false; }
            return true;
        }

        // ------------------------------------------------------------------
        // Recovery request/result plumbing and diagnostics
        // ------------------------------------------------------------------

        private sealed class ResultEnvelope
        {
            public JsonObject Result;
            public string Classification = "missing-result";
        }

        private static ResultEnvelope ReadRecoveryResultEnvelope(string requestId)
        {
            ResultEnvelope envelope = new ResultEnvelope();
            string resultRoot = GetRecoveryResultPath();
            string resultPath = Path.Combine(resultRoot, requestId + ".json");
            if (!File.Exists(resultPath))
            {
                envelope.Classification = Directory.Exists(resultRoot) && Directory.GetFiles(resultRoot, "*.json").Length > 0 ? "stale-result" : "missing-result";
                return envelope;
            }
            try
            {
                JsonObject result = JsonParse(ReadAllTextShared(resultPath)) as JsonObject;
                if (result == null || !result.ContainsKey("requestId"))
                {
                    envelope.Classification = "stale-result";
                    return envelope;
                }
                if (!string.Equals(GetString(result.Get("requestId")), requestId, StringComparison.OrdinalIgnoreCase))
                {
                    envelope.Classification = "stale-result";
                    return envelope;
                }
                envelope.Result = result;
                envelope.Classification = "success";
                return envelope;
            }
            catch
            {
                envelope.Classification = "stale-result";
                return envelope;
            }
        }

        private sealed class TaskDiagnostics
        {
            public string TaskState = "";
            public long? TaskLastResult;
            public string TaskLastResultHex = "";
            public string TaskLastRunTime = "";
            public string TaskNextRunTime = "";
            public int? TaskNumberOfMissedRuns;
            public string TaskDiagnosticsError = "";
        }

        private static TaskDiagnostics QueryTaskDiagnostics(string taskName)
        {
            TaskDiagnostics diagnostics = new TaskDiagnostics();
            try
            {
                System.Diagnostics.ProcessStartInfo info = new System.Diagnostics.ProcessStartInfo();
                info.FileName = "schtasks.exe";
                info.Arguments = "/Query /TN " + QuoteArgument(taskName) + " /FO LIST /V";
                info.UseShellExecute = false;
                info.CreateNoWindow = true;
                info.RedirectStandardOutput = true;
                info.RedirectStandardError = true;
                string output;
                using (System.Diagnostics.Process process = System.Diagnostics.Process.Start(info))
                {
                    output = process.StandardOutput.ReadToEnd();
                    process.StandardError.ReadToEnd();
                    process.WaitForExit(30000);
                }
                foreach (string rawLine in output.Split(new string[] { "\r\n", "\n" }, StringSplitOptions.None))
                {
                    int colon = rawLine.IndexOf(':');
                    if (colon <= 0) { continue; }
                    string key = rawLine.Substring(0, colon).Trim();
                    string value = rawLine.Substring(colon + 1).Trim();
                    if (key == "Status" || key == "Estado") { diagnostics.TaskState = value; }
                    else if (key == "Last Result" || key == "Ultimo resultado" || key == "Último resultado") { long parsed; if (long.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)) { diagnostics.TaskLastResult = parsed; diagnostics.TaskLastResultHex = "0x" + ((uint)(parsed & 0xffffffffL)).ToString("X8", CultureInfo.InvariantCulture); } }
                    else if (key == "Last Run Time" || key == "Ultima hora de ejecucion" || key == "Última hora de ejecución") { diagnostics.TaskLastRunTime = value; }
                    else if (key == "Next Run Time" || key == "Proxima hora de ejecucion" || key == "Próxima hora de ejecución") { diagnostics.TaskNextRunTime = value; }
                    else if (key == "Missed Runs" || key == "Ejecuciones omitidas") { int parsed; if (int.TryParse(value, NumberStyles.Integer, CultureInfo.InvariantCulture, out parsed)) { diagnostics.TaskNumberOfMissedRuns = parsed; } }
                }
                return diagnostics;
            }
            catch
            {
                diagnostics.TaskDiagnosticsError = "schtasks-query-failed";
                return diagnostics;
            }
        }

        private sealed class DirectorySnapshot
        {
            public int Count;
            public List<string> RequestIds = new List<string>();
            public string LatestPhase = "";
        }

        private static DirectorySnapshot SnapshotDirectory(string path, string phaseProperty)
        {
            DirectorySnapshot snapshot = new DirectorySnapshot();
            if (!Directory.Exists(path)) { return snapshot; }
            string[] files = Directory.GetFiles(path, "*.json");
            Array.Sort(files, delegate(string left, string right)
            {
                int byWrite = File.GetLastWriteTimeUtc(left).CompareTo(File.GetLastWriteTimeUtc(right));
                if (byWrite != 0) { return byWrite; }
                return string.CompareOrdinal(left, right);
            });
            snapshot.Count = files.Length;
            for (int index = 0; index < files.Length; index++)
            {
                string requestId = Path.GetFileNameWithoutExtension(files[index]);
                JsonObject payload = null;
                try { payload = JsonParse(ReadAllTextShared(files[index])) as JsonObject; } catch { }
                if (payload != null && payload.ContainsKey("requestId") && GetString(payload.Get("requestId")).Length > 0)
                {
                    requestId = GetString(payload.Get("requestId"));
                }
                if (requestId.Length > 0 && !snapshot.RequestIds.Contains(requestId)) { snapshot.RequestIds.Add(requestId); }
                if (phaseProperty.Length > 0 && index == files.Length - 1 && payload != null && payload.ContainsKey(phaseProperty))
                {
                    snapshot.LatestPhase = GetString(payload.Get(phaseProperty));
                }
            }
            return snapshot;
        }

        private static void AddRecoveryDiagnostics(JsonObject response, JsonObject taskResult, string taskName)
        {
            if (taskResult != null)
            {
                TaskDiagnostics diagnostics = QueryTaskDiagnostics(taskName);
                response.Set("taskState", diagnostics.TaskState);
                response.Set("taskLastResult", diagnostics.TaskLastResult.HasValue ? (object)diagnostics.TaskLastResult.Value : null);
                response.Set("taskLastResultHex", diagnostics.TaskLastResultHex);
                response.Set("taskLastRunTime", diagnostics.TaskLastRunTime);
                response.Set("taskNextRunTime", diagnostics.TaskNextRunTime);
                response.Set("taskNumberOfMissedRuns", diagnostics.TaskNumberOfMissedRuns.HasValue ? (object)diagnostics.TaskNumberOfMissedRuns.Value : null);
                response.Set("taskDiagnosticsError", diagnostics.TaskDiagnosticsError);
            }
            string queuePath = GetRecoveryQueuePath();
            string resultPath = GetRecoveryResultPath();
            string progressPath = GetRecoveryProgressPath();
            DirectorySnapshot queue = SnapshotDirectory(queuePath, "");
            DirectorySnapshot results = SnapshotDirectory(resultPath, "");
            DirectorySnapshot progress = SnapshotDirectory(progressPath, "phase");
            response.Set("queuePath", queuePath);
            response.Set("resultPath", resultPath);
            response.Set("progressPath", progressPath);
            response.Set("queueFileCount", queue.Count);
            response.Set("resultFileCount", results.Count);
            response.Set("progressFileCount", progress.Count);
            response.Set("pendingRequestIds", queue.RequestIds);
            response.Set("resultRequestIds", results.RequestIds);
            response.Set("progressRequestIds", progress.RequestIds);
            response.Set("latestProgressPhase", progress.LatestPhase);
        }

        private static string ClassifyRecoveryQueue(string readClassification, JsonObject taskResult, JsonObject result, string operation, bool operationSucceeded)
        {
            if (result != null)
            {
                string state = GetString(result.Get("state"));
                string portalExitRoute = GetString(result.Get("portalExitRoute"));
                if (state == "Authenticated" && !operationSucceeded && (portalExitRoute.IndexOf("authenticated-restore-failed", StringComparison.OrdinalIgnoreCase) >= 0 || operation == "reconcile"))
                {
                    return "authenticated-restore-failed";
                }
                return "success";
            }
            if (taskResult != null)
            {
                string taskState = GetString(taskResult.Get("taskState"));
                string taskError = GetString(taskResult.Get("error"));
                if (taskState.IndexOf("disabled", StringComparison.OrdinalIgnoreCase) >= 0 || taskError.IndexOf("disabled", StringComparison.OrdinalIgnoreCase) >= 0) { return "task-disabled"; }
                if (GetBool(taskResult.Get("timedOut"), false) || System.Text.RegularExpressions.Regex.IsMatch(taskError, "(?i)timed out|timeout")) { return "task-timeout"; }
            }
            if (readClassification == "stale-result") { return "stale-result"; }
            return "missing-result";
        }

        // recover-captive-portal-navigation.
        private static JsonObject RecoveryAction(JsonObject message, int timeoutSeconds)
        {
            string action = "recover-captive-portal-navigation";
            string taskName = "OpenPath-CaptivePortalRecovery";
            int boundedTimeout = Math.Max(1, Math.Min(90, timeoutSeconds));
            string operation = "open";
            string operationRaw = GetString(message.Get("operation")).Trim().ToLowerInvariant();
            if (operationRaw == "open" || operationRaw == "reconcile") { operation = operationRaw; }
            string portalState = GetString(message.Get("portalState")).Length > 0 ? GetString(message.Get("portalState")) : "Unknown";
            string source = GetString(message.Get("source")).Length > 0 ? GetString(message.Get("source")) : "native-host";
            string triggerHost = NormalizeHost(GetString(message.Get("triggerHost")));
            List<string> portalRecoveryHosts = GetRecoveryHosts(triggerHost, message.Get("portalRecoveryHosts"));

            if (operation == "open" && triggerHost.Length == 0)
            {
                JsonObject invalid = new JsonObject();
                invalid.Add("success", false);
                invalid.Add("action", action);
                invalid.Add("state", "InvalidHost");
                invalid.Add("portalModeActive", false);
                invalid.Add("triggerHost", "");
                invalid.Add("requestId", "");
                invalid.Add("taskName", taskName);
                invalid.Add("triggerMs", 0);
                invalid.Add("waitMs", 0);
                invalid.Add("error", "Invalid captive portal trigger host");
                return invalid;
            }

            RecentPortalSuccess recentSuccess = operation == "open" ? GetRecentPortalSuccess() : null;
            if (recentSuccess != null && TestRecentSuccessEligible(recentSuccess, triggerHost))
            {
                List<string> configured = GetConfiguredPortalDomains();
                List<string> portalHosts = recentSuccess.PortalRecoveryHosts.Count > 0 ? recentSuccess.PortalRecoveryHosts : portalRecoveryHosts;
                JsonObject response = new JsonObject();
                response.Add("success", true);
                response.Add("action", action);
                response.Add("operation", operation);
                response.Add("state", "RecentSuccess");
                response.Add("portalModeActive", true);
                response.Add("triggerHost", triggerHost);
                response.Add("requestId", recentSuccess.RequestId);
                response.Add("taskName", taskName);
                response.Add("triggerMs", 0);
                response.Add("waitMs", 0);
                response.Add("recentSuccess", true);
                response.Add("recentSuccessSource", recentSuccess.Source);
                response.Add("recentSuccessEligible", recentSuccess.RecentSuccessEligible);
                response.Add("activeMarkerMode", recentSuccess.ActiveMarkerMode);
                response.Add("allowedHosts", recentSuccess.AllowedHosts);
                response.Add("effectiveExactHosts", recentSuccess.EffectiveExactHosts.Count > 0 ? recentSuccess.EffectiveExactHosts : recentSuccess.AllowedHosts);
                response.Add("configuredCaptivePortalDomains", recentSuccess.ConfiguredDomains.Count > 0 ? recentSuccess.ConfiguredDomains : configured);
                response.Add("configuredCaptivePortalDomainsApplied", recentSuccess.ConfiguredApplied || ConfiguredPortalDomainsApplied(recentSuccess.AllowedHosts, configured));
                response.Add("portalRecoveryHosts", portalHosts);
                response.Add("bootstrapHosts", recentSuccess.BootstrapHosts);
                response.Add("redirectHosts", recentSuccess.RedirectHosts);
                response.Add("resourceHosts", recentSuccess.ResourceHosts);
                response.Add("observedRuntimeHosts", recentSuccess.ObservedRuntimeHosts);
                response.Add("pendingRuntimeHosts", recentSuccess.PendingRuntimeHosts);
                response.Add("discoveryTruncated", recentSuccess.DiscoveryTruncated);
                response.Add("fallbackMode", recentSuccess.FallbackMode);
                response.Add("limitedModeReady", recentSuccess.LimitedModeReady);
                response.Add("recoveryHostsApplied", recentSuccess.RecoveryHostsApplied);
                return response;
            }

            string requestId = Guid.NewGuid().ToString("N");
            WriteRecoveryRequest(requestId, triggerHost, portalRecoveryHosts, operation, portalState, source, message.Get("tabId"));

            JsonObject taskResult = null;
            string waitPath = Path.Combine(GetRecoveryResultPath(), requestId + ".json");
            try
            {
                Mutex mutex = new Mutex(false, @"Global\OpenPathCaptivePortalRecoveryTrigger");
                bool acquired = false;
                try
                {
                    try { acquired = mutex.WaitOne(boundedTimeout * 1000); }
                    catch (AbandonedMutexException) { acquired = true; }
                    if (!acquired) { throw new InvalidOperationException("Timed out waiting for Global\\OpenPathCaptivePortalRecoveryTrigger"); }

                    TaskRunResult run = RunScheduledTask(taskName);
                    taskResult = new JsonObject();
                    taskResult.Add("success", run.Success);
                    taskResult.Add("taskName", taskName);
                    taskResult.Add("exitCode", run.ExitCode);
                    taskResult.Add("triggerMs", run.ElapsedMs);
                    taskResult.Add("waitMs", 0);
                    if (!run.Success)
                    {
                        taskResult.Add("error", "schtasks exit code " + run.ExitCode.ToString(CultureInfo.InvariantCulture));
                    }
                    else
                    {
                        int waitMs = 0;
                        bool ready = WaitCondition(delegate { return File.Exists(waitPath); }, boundedTimeout, 250, out waitMs);
                        taskResult.Set("waitMs", waitMs);
                        if (!ready)
                        {
                            taskResult.Add("timedOut", true);
                            taskResult.Add("error", "Timed out waiting for task condition");
                        }
                        else { taskResult.Add("timedOut", false); }
                    }
                }
                finally
                {
                    if (acquired)
                    {
                        try { mutex.ReleaseMutex(); }
                        catch { }
                    }
                    mutex.Dispose();
                }
            }
            catch (Exception exception)
            {
                JsonObject failed = new JsonObject();
                failed.Add("success", false);
                failed.Add("action", action);
                failed.Add("operation", operation);
                failed.Add("state", "TriggerFailed");
                failed.Add("portalModeActive", false);
                failed.Add("triggerHost", triggerHost);
                failed.Add("requestId", requestId);
                failed.Add("taskName", taskName);
                failed.Add("triggerMs", 0);
                failed.Add("waitMs", 0);
                failed.Add("error", exception.Message);
                return AddRecoveryDiagnosticsAndReturn(failed, taskResult, taskName);
            }

            string taskNameResult = taskResult != null && GetString(taskResult.Get("taskName")).Length > 0 ? GetString(taskResult.Get("taskName")) : taskName;
            int triggerMs = taskResult != null ? (int)GetLong(taskResult.Get("triggerMs"), 0) : 0;
            int waitMsValue = taskResult != null ? (int)GetLong(taskResult.Get("waitMs"), 0) : 0;

            ResultEnvelope envelope = ReadRecoveryResultEnvelope(requestId);
            JsonObject result = envelope.Result;
            if (result == null)
            {
                string classification = ClassifyRecoveryQueue(envelope.Classification, taskResult, null, operation, false);
                JsonObject timeout = new JsonObject();
                timeout.Add("success", false);
                timeout.Add("action", action);
                timeout.Add("operation", operation);
                timeout.Add("state", "Timeout");
                timeout.Add("portalModeActive", false);
                timeout.Add("triggerHost", triggerHost);
                timeout.Add("requestId", requestId);
                timeout.Add("taskName", taskNameResult);
                timeout.Add("triggerMs", triggerMs);
                timeout.Add("waitMs", waitMsValue);
                timeout.Add("recoveryQueueClassification", classification);
                string taskError = taskResult == null ? "" : GetString(taskResult.Get("error"));
                timeout.Add("error", taskError.Length > 0 ? taskError : "Timed out waiting for captive portal recovery result");
                return AddRecoveryDiagnosticsAndReturn(timeout, taskResult, taskName);
            }

            string state = GetString(result.Get("state")).Length > 0 ? GetString(result.Get("state")) : "Unknown";
            bool portalModeActive = GetBool(result.Get("portalModeActive"), false);
            bool resultSuccess = GetBool(result.Get("success"), false);
            bool protectedModeRestored = GetBool(result.Get("protectedModeRestored"), false);
            List<string> allowedHosts = StringList(result.Get("allowedHosts"));
            List<string> resultRecoveryHosts = result.ContainsKey("portalRecoveryHosts") ? StringList(result.Get("portalRecoveryHosts")) : portalRecoveryHosts;
            List<string> configuredFinal = result.ContainsKey("configuredCaptivePortalDomains") ? StringList(result.Get("configuredCaptivePortalDomains")) : GetConfiguredPortalDomains();
            List<string> effectiveExactHosts = result.ContainsKey("effectiveExactHosts") ? StringList(result.Get("effectiveExactHosts")) : GetPortalEffectiveHosts(Concat(allowedHosts, configuredFinal));
            bool configuredApplied = result.ContainsKey("configuredCaptivePortalDomainsApplied") ? GetBool(result.Get("configuredCaptivePortalDomainsApplied"), false) : ConfiguredPortalDomainsApplied(allowedHosts, configuredFinal);
            bool recoveryHostsApplied = GetBool(result.Get("recoveryHostsApplied"), false);
            bool limitedModeReady = GetBool(result.Get("limitedModeReady"), false);
            bool exactRecoveryHostApplied = recoveryHostsApplied;
            if (triggerHost.Length > 0)
            {
                bool found = false;
                foreach (string host in allowedHosts) { if (string.Equals(host, triggerHost, StringComparison.OrdinalIgnoreCase)) { found = true; break; } }
                exactRecoveryHostApplied = exactRecoveryHostApplied && found;
            }
            bool localDnsLoopbackRestored = GetBool(result.Get("localDnsLoopbackRestored"), false);
            bool acrylicNormalRestored = GetBool(result.Get("acrylicNormalRestored"), false);
            bool dnsResolutionHealthy = GetBool(result.Get("dnsResolutionHealthy"), false);
            bool sinkholeHealthy = GetBool(result.Get("sinkholeHealthy"), false);
            bool firewallExpectedActive = GetBool(result.Get("firewallExpectedActive"), false);
            bool firewallHealthy = GetBool(result.Get("firewallHealthy"), false);
            bool markerCleared = GetBool(result.Get("markerCleared"), false);
            bool postAuthRestored = protectedModeRestored && localDnsLoopbackRestored && acrylicNormalRestored && dnsResolutionHealthy && sinkholeHealthy && ((!firewallExpectedActive) || firewallHealthy) && markerCleared;
            bool operationSucceeded;
            if (operation == "reconcile")
            {
                operationSucceeded = resultSuccess && state == "Authenticated" && !portalModeActive && postAuthRestored;
            }
            else
            {
                operationSucceeded = resultSuccess && (
                    (state == "Portal" && portalModeActive && exactRecoveryHostApplied && limitedModeReady && configuredApplied) ||
                    (state == "Authenticated" && !portalModeActive && postAuthRestored));
            }
            string queueClassification = ClassifyRecoveryQueue(envelope.Classification, taskResult, result, operation, operationSucceeded);

            JsonObject response2 = new JsonObject();
            response2.Add("success", operationSucceeded);
            response2.Add("action", action);
            response2.Add("operation", operation);
            response2.Add("state", state);
            response2.Add("portalModeActive", portalModeActive);
            response2.Add("triggerHost", triggerHost);
            response2.Add("requestId", requestId);
            response2.Add("taskName", taskNameResult);
            response2.Add("triggerMs", triggerMs);
            response2.Add("waitMs", waitMsValue);
            response2.Add("recoveryQueueClassification", queueClassification);
            response2.Add("portalExitRoute", GetString(result.Get("portalExitRoute")));
            response2.Add("localDnsLoopbackRestored", localDnsLoopbackRestored);
            response2.Add("acrylicNormalRestored", acrylicNormalRestored);
            response2.Add("dnsResolutionHealthy", dnsResolutionHealthy);
            response2.Add("sinkholeHealthy", sinkholeHealthy);
            response2.Add("firewallExpectedActive", firewallExpectedActive);
            response2.Add("firewallHealthy", firewallHealthy);
            response2.Add("markerCleared", markerCleared);
            response2.Add("protectedModeRestored", protectedModeRestored);
            response2.Add("activeMarkerMode", GetString(result.Get("activeMarkerMode")));
            response2.Add("allowedHosts", allowedHosts);
            response2.Add("effectiveExactHosts", effectiveExactHosts);
            response2.Add("configuredCaptivePortalDomains", configuredFinal);
            response2.Add("configuredCaptivePortalDomainsApplied", configuredApplied);
            response2.Add("portalRecoveryHosts", resultRecoveryHosts);
            response2.Add("bootstrapHosts", StringList(result.Get("bootstrapHosts")));
            response2.Add("redirectHosts", StringList(result.Get("redirectHosts")));
            response2.Add("resourceHosts", StringList(result.Get("resourceHosts")));
            response2.Add("observedRuntimeHosts", StringList(result.Get("observedRuntimeHosts")));
            response2.Add("pendingRuntimeHosts", StringList(result.Get("pendingRuntimeHosts")));
            response2.Add("discoveryTruncated", GetBool(result.Get("discoveryTruncated"), false));
            response2.Add("fallbackMode", result.ContainsKey("fallbackMode") && GetString(result.Get("fallbackMode")).Length > 0 ? GetString(result.Get("fallbackMode")) : "none");
            response2.Add("limitedModeReady", limitedModeReady);
            response2.Add("recoveryHostsApplied", recoveryHostsApplied);
            response2.Add("recentSuccessEligible", GetBool(result.Get("recentSuccessEligible"), false));
            return response2;
        }

        private static JsonObject AddRecoveryDiagnosticsAndReturn(JsonObject response, JsonObject taskResult, string taskName)
        {
            AddRecoveryDiagnostics(response, taskResult, taskName);
            return response;
        }

        private static void WriteRecoveryRequest(string requestId, string triggerHost, List<string> portalRecoveryHosts, string operation, string portalState, string source, object tabId)
        {
            string queuePath = GetRecoveryQueuePath();
            Directory.CreateDirectory(queuePath);
            JsonObject request = new JsonObject();
            request.Add("requestId", requestId);
            request.Add("operation", operation);
            request.Add("triggerHost", triggerHost);
            request.Add("portalRecoveryHosts", portalRecoveryHosts);
            request.Add("portalState", portalState);
            request.Add("source", source);
            request.Add("createdAtUtc", DateTime.UtcNow.ToString("o", CultureInfo.InvariantCulture));
            if (tabId != null)
            {
                int parsedInt;
                if (tabId is int) { request.Add("tabId", (int)tabId); }
                else if (int.TryParse(GetString(tabId), NumberStyles.Integer, CultureInfo.InvariantCulture, out parsedInt)) { request.Add("tabId", parsedInt); }
                else { request.Add("tabId", GetString(tabId)); }
            }
            WriteAllTextUtf8(Path.Combine(queuePath, requestId + ".json"), JsonString(request));
        }

        // Invoke-NativeHostAuthenticatedCaptivePortalRestoreIfNeeded.
        private static void InvokeAuthenticatedCaptivePortalRestoreIfNeeded()
        {
            try
            {
                JsonObject marker = ReadPortalMarker();
                if (marker == null) { return; }
                string cacheKey = "authenticated-marker-restore";
                DateTime now = DateTime.UtcNow;
                PortalProbeCacheEntry cached;
                if (PortalProbeCache.TryGetValue(cacheKey, out cached))
                {
                    if (cached != null && (now - cached.ProbedAtUtc).TotalSeconds < 15) { return; }
                }
                PortalProbeCacheEntry entry = new PortalProbeCacheEntry();
                entry.ProbedAtUtc = now;
                entry.Signal = "restore-probe";
                PortalProbeCache[cacheKey] = entry;
                if (TestPortalState(2) != "Authenticated") { return; }
                JsonObject message = new JsonObject();
                message.Add("operation", "reconcile");
                message.Add("portalState", "authenticated");
                message.Add("source", "native-host-check");
                RecoveryAction(message, 8);
            }
            catch { }
        }

        // ------------------------------------------------------------------
        // report-extension-diagnostics
        // ------------------------------------------------------------------

        private static readonly string[] DiagnosticAllowedFields = new string[]
        {
            "ts", "kind", "tabId", "frameId", "type", "anchorHost", "dependencyHost", "host",
            "transport", "from", "to", "outcome", "ms", "reason", "navigationId", "methodKnown",
            "committed", "source"
        };

        private static DateTime _diagnosticWindowStart = DateTime.MinValue;
        private static int _diagnosticWindowMessages;
        private static bool _diagnosticFirstLogged;

        private static JsonObject SanitizeDiagnosticEvent(JsonObject candidate)
        {
            JsonObject sanitized = new JsonObject();
            if (candidate == null) { return sanitized; }
            foreach (string field in DiagnosticAllowedFields)
            {
                if (!candidate.ContainsKey(field)) { continue; }
                object value = candidate.Get(field);
                if (value == null) { continue; }
                if (value is bool) { sanitized.Add(field, (bool)value); continue; }
                if (value is int || value is long)
                {
                    sanitized.Add(field, GetLong(value, 0));
                    continue;
                }
                if (value is double)
                {
                    sanitized.Add(field, Math.Round((double)value, 3));
                    continue;
                }
                string text = GetString(value).Trim();
                if (text.Length == 0) { continue; }
                if (System.Text.RegularExpressions.Regex.IsMatch(text, "^[a-zA-Z][a-zA-Z0-9+.-]*://")) { continue; }
                if (text.Length > 120) { text = text.Substring(0, 120); }
                sanitized.Add(field, text);
            }
            return sanitized;
        }

        private static JsonObject ReportExtensionDiagnostics(JsonObject message)
        {
            int written = 0;
            int dropped = 0;
            try
            {
                DateTime now = DateTime.UtcNow;
                if (_diagnosticWindowStart == DateTime.MinValue || (now - _diagnosticWindowStart).TotalSeconds >= 60)
                {
                    _diagnosticWindowStart = now;
                    _diagnosticWindowMessages = 0;
                }
                _diagnosticWindowMessages++;
                if (_diagnosticWindowMessages > 60)
                {
                    JsonObject limited = new JsonObject();
                    limited.Add("success", true);
                    limited.Add("action", "report-extension-diagnostics");
                    limited.Add("written", 0);
                    limited.Add("rateLimited", true);
                    return limited;
                }
                List<object> events = AsArray(message == null ? null : message.Get("events"));
                int eventCount = events == null ? 0 : events.Count;
                if (events != null)
                {
                    int index = 0;
                    foreach (object item in events)
                    {
                        if (index >= 50) { break; }
                        index++;
                        try
                        {
                            JsonObject sanitized = SanitizeDiagnosticEvent(item as JsonObject);
                            if (sanitized.Count == 0) { dropped++; continue; }
                            WriteCompatLog("stage=extension-diagnostic " + JsonString(sanitized));
                            written++;
                        }
                        catch { dropped++; }
                    }
                    if (eventCount > 50) { dropped += eventCount - 50; }
                }
                if (!_diagnosticFirstLogged)
                {
                    _diagnosticFirstLogged = true;
                    WriteCompatLog("stage=extension-diagnostic-batch first=true received=" + eventCount.ToString(CultureInfo.InvariantCulture) +
                        " written=" + written.ToString(CultureInfo.InvariantCulture) +
                        " dropped=" + dropped.ToString(CultureInfo.InvariantCulture) +
                        " pid=" + System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
                }
                JsonObject response = new JsonObject();
                response.Add("success", true);
                response.Add("action", "report-extension-diagnostics");
                response.Add("written", written);
                response.Add("dropped", dropped);
                return response;
            }
            catch (Exception exception)
            {
                JsonObject failure = new JsonObject();
                failure.Add("success", false);
                failure.Add("action", "report-extension-diagnostics");
                failure.Add("error", "extension diagnostics failed: " + exception.Message);
                return failure;
            }
        }

        // ------------------------------------------------------------------
        // Dispatch and main loop
        // ------------------------------------------------------------------

        private static bool IsChattyAction(string action)
        {
            return action == "check-local-runtime-dependency" || action == "get-policy-version" ||
                action == "get-blocked-paths" || action == "get-blocked-subdomains" ||
                action == "get-allowed-paths" || action == "report-extension-diagnostics";
        }

        private static readonly Dictionary<string, int> ChattyStatsCount = new Dictionary<string, int>(StringComparer.Ordinal);
        private static readonly Dictionary<string, DateTime> ChattyStatsAt = new Dictionary<string, DateTime>(StringComparer.Ordinal);

        private static void WriteChattyAggregate(string action)
        {
            try
            {
                DateTime now = DateTime.UtcNow;
                if (!ChattyStatsCount.ContainsKey(action))
                {
                    ChattyStatsCount[action] = 0;
                    ChattyStatsAt[action] = now;
                }
                ChattyStatsCount[action] = ChattyStatsCount[action] + 1;
                double elapsedSeconds = (now - ChattyStatsAt[action]).TotalSeconds;
                if (elapsedSeconds >= 60 || ChattyStatsCount[action] >= 500)
                {
                    WriteStageLog("chatty-aggregate", null, "", 0, StageFields("action", action, "count", ChattyStatsCount[action].ToString(CultureInfo.InvariantCulture), "windowSeconds", ((int)elapsedSeconds).ToString(CultureInfo.InvariantCulture)));
                    ChattyStatsCount[action] = 0;
                    ChattyStatsAt[action] = now;
                }
            }
            catch { }
        }

        private static JsonObject HandleMessage(object messageRaw)
        {
            JsonObject message = messageRaw as JsonObject;
            if (message == null)
            {
                if (messageRaw == null)
                {
                    JsonObject invalid = new JsonObject();
                    invalid.Add("success", false);
                    invalid.Add("error", "Invalid message format");
                    return invalid;
                }
                message = new JsonObject();
            }
            JsonObject state = ReadNativeState();
            WhitelistSections sections = GetWhitelistSections();
            string action = GetString(message.Get("action"));
            System.Diagnostics.Stopwatch stopwatch = System.Diagnostics.Stopwatch.StartNew();
            JsonObject result = null;
            try
            {
                result = DispatchAction(message, state, sections, action);
            }
            catch (Exception exception)
            {
                result = new JsonObject();
                result.Add("success", false);
                result.Add("action", action);
                result.Add("error", exception.Message);
            }
            stopwatch.Stop();

            if (action != "update-whitelist")
            {
                string logMessage = GetString(result.Get("message"));
                string logError = GetString(result.Get("error"));
                List<string> domains = new List<string>();
                if (action == "check")
                {
                    domains = GetMessageDomains(message);
                }
                else if (result.ContainsKey("dependencyHost"))
                {
                    domains.Add(GetString(result.Get("dependencyHost")));
                }
                else if (result.ContainsKey("results"))
                {
                    List<object> results = AsArray(result.Get("results"));
                    if (results != null)
                    {
                        foreach (object item in results)
                        {
                            JsonObject entry = item as JsonObject;
                            if (entry != null && entry.ContainsKey("dependencyHost")) { domains.Add(GetString(entry.Get("dependencyHost"))); }
                        }
                    }
                }
                JsonObject extraFields = new JsonObject();
                foreach (string key in new string[] { "queueWriteMs", "updateTriggerMs", "updateWaitMs", "updateElapsedMs", "runtimeDependencyFastPath", "runtimeDependencyFallback", "updateTaskName" })
                {
                    if (result.ContainsKey(key)) { extraFields.Add(key, result.Get(key)); }
                }
                if (IsChattyAction(action)) { WriteChattyAggregate(action); }
                else { WriteActionLog(action, domains, GetBool(result.Get("success"), false), logMessage, logError, stopwatch.ElapsedMilliseconds, extraFields); }
            }

            if (message.ContainsKey("id"))
            {
                object messageId = message.Get("id");
                if (messageId != null && GetString(messageId).Trim().Length > 0)
                {
                    result.Set("id", messageId);
                }
            }
            return result;
        }

        private static JsonObject DispatchAction(JsonObject message, JsonObject state, WhitelistSections sections, string action)
        {
            switch (action)
            {
                case "ping": return PingResponse(state);
                case "get-hostname": return HostnameResponse(state);
                case "get-machine-token": return MachineTokenResponse(state);
                case "get-config": return ConfigResponse(state);
                case "get-blocked-paths": return PathsResponse(sections, "get-blocked-paths", sections.BlockedPaths);
                case "get-allowed-paths": return PathsResponse(sections, "get-allowed-paths", sections.AllowedPaths);
                case "get-blocked-subdomains": return BlockedSubdomainsResponse(sections);
                case "check": return CheckResponse(message, sections, state);
                case "get-policy-version": return PolicyVersionResponse(sections);
                case "update-whitelist":
                    return UpdateTask(GetMessageDomains(message), null, "", 45);
                case ActionAllowLocal: return LocalDependencyAction(message, sections, state);
                case ActionAllowLocalBatch: return LocalDependencyBatchAction(message, sections, state);
                case ActionCheckLocal: return CheckLocalDependencyAction(message);
                case "recover-captive-portal-navigation": return RecoveryAction(message, 90);
                case "report-extension-diagnostics": return ReportExtensionDiagnostics(message);
                default:
                    JsonObject unknown = new JsonObject();
                    unknown.Add("success", false);
                    unknown.Add("error", "Unknown action: " + action);
                    return unknown;
            }
        }

        private static bool _startupProfileWritten;
        private static bool _startupPingDone;
        private static bool _startupEnqueueDone;
        private static long _startupPingMs = -1;
        private static long _startupFirstEnqueueMs = -1;
        private static long _startupFirstEnqueueAtMs = -1;

        private static void WriteStartupProfile()
        {
            if (_startupProfileWritten) { return; }
            _startupProfileWritten = true;
            try
            {
                JsonObject fields = new JsonObject();
                fields.Add("processToScriptMs", 0);
                fields.Add("loadsMs", "");
                fields.Add("loads2Ms", "");
                fields.Add("pingMs", _startupPingMs);
                fields.Add("firstEnqueueMs", _startupFirstEnqueueMs);
                fields.Add("firstEnqueueAtMs", _startupFirstEnqueueAtMs);
                // "" fields are dropped by WriteStageLog, matching the reference.
                WriteStageLog("startup-profile", null, "", 0, fields);
            }
            catch { }
        }

        private static int Main()
        {
            try
            {
                Console.OutputEncoding = new UTF8Encoding(false);
            }
            catch { }
            WriteCompatLog("Native host initialization completed pid=" + System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture) + " log=" + GetLogPath());
            long messageCount = 0;
            while (true)
            {
                try
                {
                    object message = ReadMessage();
                    if (message == null) { break; }
                    messageCount++;
                    string messageAction = "";
                    JsonObject messageObject = message as JsonObject;
                    if (messageObject != null) { messageAction = GetString(messageObject.Get("action")); }
                    System.Diagnostics.Stopwatch messageStopwatch = System.Diagnostics.Stopwatch.StartNew();
                    bool chatty = IsChattyAction(messageAction);
                    if (!chatty)
                    {
                        WriteStageLog("message-received", null, "", 0, StageFields("index", messageCount.ToString(CultureInfo.InvariantCulture), "action", messageAction));
                    }
                    JsonObject response = HandleMessage(message);
                    WriteMessage(response);
                    messageStopwatch.Stop();
                    if (chatty) { WriteChattyAggregate(messageAction); }
                    else
                    {
                        WriteStageLog("response-sent", null, "", 0, StageFields("index", messageCount.ToString(CultureInfo.InvariantCulture), "action", messageAction, "totalMs", messageStopwatch.ElapsedMilliseconds.ToString(CultureInfo.InvariantCulture)));
                    }
                    if (!_startupProfileWritten)
                    {
                        if (messageAction == "ping" && !_startupPingDone)
                        {
                            _startupPingDone = true;
                            _startupPingMs = GetProcessElapsedMs();
                        }
                        else if (!_startupEnqueueDone && (messageAction == ActionAllowLocal || messageAction == ActionAllowLocalBatch))
                        {
                            _startupEnqueueDone = true;
                            _startupFirstEnqueueMs = messageStopwatch.ElapsedMilliseconds;
                            _startupFirstEnqueueAtMs = GetProcessElapsedMs();
                        }
                        if (_startupPingDone && (_startupEnqueueDone || messageCount >= 10))
                        {
                            WriteStartupProfile();
                        }
                    }
                }
                catch (Exception exception)
                {
                    WriteCompatLog("Fatal protocol error: " + exception.Message);
                    try
                    {
                        JsonObject failure = new JsonObject();
                        failure.Add("success", false);
                        failure.Add("error", exception.Message);
                        WriteMessage(failure);
                    }
                    catch { break; }
                }
            }
            WriteStartupProfile();
            WriteCompatLog("Native host process exiting pid=" + System.Diagnostics.Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture));
            return 0;
        }
    }
}

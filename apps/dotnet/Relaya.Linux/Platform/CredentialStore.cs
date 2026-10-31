using System;
using System.Runtime.InteropServices;

namespace Relaya.Platform;

/// Пароли хостов в Secret Service (GNOME Keyring, KWallet) через libsecret — аналог Keychain и Credential Manager.
/// Схема app.relaya.Password, атрибут account = алиас; подпись «Relaya/<алиас>», как на Windows.
/// Используются *v-функции libsecret: в них нет varargs, P/Invoke одинаково работает на x86_64 и aarch64.
internal static class CredentialStore
{
    private const string Secret = "libsecret-1.so.0", Glib = "libglib-2.0.so.0";
    private static readonly Lazy<IntPtr> schema = new(CreateSchema);

    public static string? Read(string account)
    {
        try
        {
            var attrs = Attributes(account);
            try
            {
                var p = secret_password_lookupv_sync(schema.Value, attrs, IntPtr.Zero, out var error);
                Drop(error);
                if (p == IntPtr.Zero) return null;
                try { return Marshal.PtrToStringUTF8(p); }
                finally { secret_password_free(p); }
            }
            finally { g_hash_table_unref(attrs); }
        }
        catch (DllNotFoundException) { return null; } // нет libsecret — паролей нет, как пустое хранилище
    }

    public static bool Has(string account) => Read(account) != null;

    public static void Write(string account, string secret)
    {
        var attrs = Attributes(account);
        try
        {
            // Коллекция по умолчанию ("default") — связка ключей входа, открывается вместе с сеансом.
            if (!secret_password_storev_sync(schema.Value, attrs, "default", "Relaya/" + account, secret, IntPtr.Zero, out var error))
                throw new InvalidOperationException(Message(error) ?? "Secret Service недоступен");
        }
        finally { g_hash_table_unref(attrs); }
    }

    public static void Delete(string account)
    {
        try
        {
            var attrs = Attributes(account);
            try { secret_password_clearv_sync(schema.Value, attrs, IntPtr.Zero, out var error); Drop(error); }
            finally { g_hash_table_unref(attrs); }
        }
        catch (DllNotFoundException) { }
    }

    // GHashTable<char*, char*> с ключами и значениями, которые освобождает сама таблица.
    private static IntPtr Attributes(string account)
    {
        var glib = NativeLibrary.Load(Glib);
        var t = g_hash_table_new_full(NativeLibrary.GetExport(glib, "g_str_hash"), NativeLibrary.GetExport(glib, "g_str_equal"),
            NativeLibrary.GetExport(glib, "g_free"), NativeLibrary.GetExport(glib, "g_free"));
        g_hash_table_insert(t, g_strdup("account"), g_strdup(account));
        return t;
    }

    // SecretSchema: name, flags, 32 × {name, type}, reserved (int + 7 указателей). Живёт до конца процесса.
    private static IntPtr CreateSchema()
    {
        var p = Marshal.AllocHGlobal(1024);
        unsafe { new Span<byte>((void*)p, 1024).Clear(); }
        Marshal.WriteIntPtr(p, 0, Marshal.StringToCoTaskMemUTF8("app.relaya.Password"));
        Marshal.WriteInt32(p, IntPtr.Size, 0); // SECRET_SCHEMA_NONE
        var attr = IntPtr.Size * 2;
        Marshal.WriteIntPtr(p, attr, Marshal.StringToCoTaskMemUTF8("account"));
        Marshal.WriteInt32(p, attr + IntPtr.Size, 0); // SECRET_SCHEMA_ATTRIBUTE_STRING
        return p;
    }

    // GError: domain (guint32), code (gint), message (gchar*).
    private static string? Message(IntPtr error)
    {
        if (error == IntPtr.Zero) return null;
        var text = Marshal.PtrToStringUTF8(Marshal.ReadIntPtr(error, 8));
        g_error_free(error);
        return text;
    }

    private static void Drop(IntPtr error) => Message(error);

    [DllImport(Secret)] private static extern IntPtr secret_password_lookupv_sync(IntPtr schema, IntPtr attributes, IntPtr cancellable, out IntPtr error);
    [DllImport(Secret)] private static extern bool secret_password_storev_sync(IntPtr schema, IntPtr attributes,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string collection, [MarshalAs(UnmanagedType.LPUTF8Str)] string label,
        [MarshalAs(UnmanagedType.LPUTF8Str)] string password, IntPtr cancellable, out IntPtr error);
    [DllImport(Secret)] private static extern bool secret_password_clearv_sync(IntPtr schema, IntPtr attributes, IntPtr cancellable, out IntPtr error);
    [DllImport(Secret)] private static extern void secret_password_free(IntPtr password);
    [DllImport(Glib)] private static extern IntPtr g_hash_table_new_full(IntPtr hash, IntPtr equal, IntPtr keyFree, IntPtr valueFree);
    [DllImport(Glib)] private static extern bool g_hash_table_insert(IntPtr table, IntPtr key, IntPtr value);
    [DllImport(Glib)] private static extern void g_hash_table_unref(IntPtr table);
    [DllImport(Glib)] private static extern IntPtr g_strdup([MarshalAs(UnmanagedType.LPUTF8Str)] string text);
    [DllImport(Glib)] private static extern void g_error_free(IntPtr error);
}

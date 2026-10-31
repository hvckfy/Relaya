using Relaya.Platform;
using Xunit;

namespace Relaya.Shared.Tests;

public class FormatTests
{
    [Theory]
    [InlineData(0, "0 B")]
    [InlineData(1023, "1023 B")]
    [InlineData(1536, "1.5 KB")]
    [InlineData(8_192_000_000, "7.6 GB")] // К8: ядро отдаёт байты, 8 ГБ — не «7.6 T»
    public void Bytes(long value, string expected) =>
        Assert.Equal(expected, Format.Bytes(value).Replace(',', '.'));
}

public class PasswordPromptTests
{
    [Theory]
    [InlineData("root@10.0.0.1's password: ", true)]
    [InlineData("Last login\nuser@host's password:", true)]
    [InlineData("[sudo] password for root:", false)]
    [InlineData("Enter passphrase for key '/home/u/.ssh/id':", false)]
    [InlineData("New password:", false)]
    [InlineData("user@host:~$ ", false)]
    public void SshLoginPrompt(string tail, bool expected) => Assert.Equal(expected, PasswordPrompt.Matches(tail));

    [Theory]
    [InlineData("[sudo] password for root:", true)]
    [InlineData("Пароль:", true)]
    [InlineData("Enter passphrase for key:", false)]
    [InlineData("user@host:~$", false)]
    public void AnyPasswordPrompt(string tail, bool expected) => Assert.Equal(expected, PasswordPrompt.IsAnyPasswordPrompt(tail));
}

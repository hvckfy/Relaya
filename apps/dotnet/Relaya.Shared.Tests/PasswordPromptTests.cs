using Relaya.Platform;
using Xunit;

namespace Relaya.Shared.Tests;

/// Пауза рассылки ввода на запросе секрета (L-SEC-1): лучше лишняя пауза, чем пароль во всех терминалах.
public class PasswordPromptTests
{
    [Theory]
    [InlineData("user@host's password: ")]
    [InlineData("[sudo] password for admin: ")]
    [InlineData("Enter passphrase for key '/home/u/.ssh/id_ed25519': ")]
    [InlineData("Пароль: ")]
    [InlineData("Введите код подтверждения")]
    [InlineData("Verification code: ")]
    [InlineData("Enter PIN > ")]
    [InlineData("Token:")]
    [InlineData("Secret? ")]
    [InlineData("Passwort: ")]
    [InlineData("Mot de passe :")]
    [InlineData("Contraseña: ")]
    [InlineData("密码：")]
    [InlineData("some output\nPassword for alice?")]
    public void SecretPromptsPause(string tail) => Assert.True(PasswordPrompt.IsSecretPrompt(tail));

    [Theory]
    [InlineData("user@host:~$ ")]
    [InlineData("root@server:/etc# ")]
    [InlineData("spinning up containers...")]
    [InlineData("shopping cart ready")]
    [InlineData("password changed\nuser@host:~$ ")]
    [InlineData("")]
    public void OrdinaryOutputDoesNotPause(string tail) => Assert.False(PasswordPrompt.IsSecretPrompt(tail));

    [Fact]
    public void SshPasswordPromptMatchesOnlySshItself()
    {
        Assert.True(PasswordPrompt.Matches("alice@host's password: "));
        Assert.False(PasswordPrompt.Matches("[sudo] password for alice: "));
    }
}

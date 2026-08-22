namespace XanhBrowser.Core;

public static class WebView2ProcessRecoveryPolicy
{
    public static Uri? SelectAutomaticTarget(Uri? currentUri, bool automaticRecoveryUsed)
    {
        return !automaticRecoveryUsed && AddressResolver.IsAllowedWebUri(currentUri)
            ? currentUri
            : null;
    }
}

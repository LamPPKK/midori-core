package io.github.lamppkk.xanhbrowser.lite.webkit;

import androidx.annotation.NonNull;

import org.wpewebkit.wpeview.WPEResourceRequest;
import org.wpewebkit.wpeview.WPEView;
import org.wpewebkit.wpeview.WPEViewClient;

// Compatibility client for Xanh's reviewed WPE source fork. The published WPEView 0.3.3
// dependency does not expose the navigation-policy method. Java permits this class to declare
// the method without @Override, so the preview remains buildable with that dependency while the
// same method becomes a virtual override when the reviewed source-fork AAR is supplied.
public class XanhWPEViewClient extends WPEViewClient {
    @FunctionalInterface
    public interface NavigationPolicy {
        boolean shouldOverride(@NonNull WPEView view, @NonNull WPEResourceRequest request,
                               boolean isRedirect, boolean hasUserGesture);
    }

    private final NavigationPolicy navigationPolicy;

    public XanhWPEViewClient(@NonNull NavigationPolicy navigationPolicy) {
        this.navigationPolicy = navigationPolicy;
    }

    public boolean shouldOverrideUrlLoading(@NonNull WPEView view, @NonNull WPEResourceRequest request,
                                            boolean isRedirect, boolean hasUserGesture) {
        return navigationPolicy.shouldOverride(view, request, isRedirect, hasUserGesture);
    }
}

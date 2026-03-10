import QtQuick
import Quickshell
import qs.Commons

Item {
    id: root

    property var pluginApi

    Component.onCompleted: {
        Logger.i("ParallaxWallpaper", "Initializing parallax wallpaper plugin");

        // Layers on top of Noctalia's native wallpaper via WlrLayer.Background
        var bgComponent = Qt.createComponent("ParallaxBackground.qml");
        if (bgComponent.status === Component.Ready) {
            bgComponent.createObject(root, { pluginApi: root.pluginApi });
        } else {
            Logger.e("ParallaxWallpaper", "Failed to load ParallaxBackground: " + bgComponent.errorString());
            bgComponent.statusChanged.connect(function() {
                if (bgComponent.status === Component.Ready) {
                    bgComponent.createObject(root, { pluginApi: root.pluginApi });
                } else if (bgComponent.status === Component.Error) {
                    Logger.e("ParallaxWallpaper", "Error loading ParallaxBackground: " + bgComponent.errorString());
                }
            });
        }
    }
}

import SwiftUI
import WidgetKit

@main
struct AppForgeWidgets: WidgetBundle {
    var body: some Widget {
        IdeaWidget()
        IdeaControl()
        TaskLiveActivity()
    }
}

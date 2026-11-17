import SwiftUI

/// Pages that swipe sideways under a slider whose thumb follows the finger.
/// The slider is Vime's own control: a soft track with a white thumb, the
/// way the keyboard's symbol panel switches modes.
struct VimePager<Page: Hashable, Content: View>: View {
    let pages: [Page]
    @Binding var selection: Page
    /// Where the pages are, in pages: 0.5 is halfway between the first two.
    @Binding var progress: CGFloat
    @ViewBuilder let content: (Page) -> Content

    var body: some View {
        // The system's page view: each page is a whole list that runs under
        // the bars, so they keep their glass and scroll edge effect.
        TabView(selection: $selection) {
            ForEach(Array(pages.enumerated()), id: \.element) { index, page in
                content(page)
                    .background {
                        // Where this page sits tells how far the swipe is.
                        // Only the left one of the two pages on screen reports,
                        // so they never disagree mid-swipe and make the thumb jump.
                        GeometryReader { proxy in
                            Color.clear.onChange(of: proxy.frame(in: .global).minX, initial: true) { _, x in
                                let width = proxy.size.width
                                guard width > 0, x <= 0.5, x > -width else { return }
                                progress = min(max(CGFloat(index) - x / width, 0), CGFloat(pages.count - 1))
                            }
                        }
                    }
                    .tag(page)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // The page view's own backdrop would show as a white band under the
        // transparent bars; the lists' grouped grey runs to the edges instead.
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .onAppear { progress = CGFloat(pages.firstIndex(of: selection) ?? 0) }
        .onChange(of: selection) { _, page in
            guard let index = pages.firstIndex(of: page) else { return }
            if abs(progress - CGFloat(index)) > 0.9 { withAnimation(.snappy) { progress = CGFloat(index) } }
        }
    }
}

/// The pager's slider. `position` comes from the pages' scrolling, so the
/// thumb moves with a swipe; a tap selects a page.
struct VimePageSlider<Page: Hashable>: View {
    let pages: [(page: Page, title: LocalizedStringKey)]
    @Binding var selection: Page
    let position: CGFloat
    var identifier = "vime.pager.slider"

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width / CGFloat(max(1, pages.count))
            let clamped = min(max(position, 0), CGFloat(pages.count - 1))
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.tertiarySystemFill))
                Capsule()
                    .fill(Color(.systemBackground))
                    .shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                    .padding(2)
                    .frame(width: width)
                    .offset(x: clamped * width)
                HStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        let near = 1 - min(1, abs(clamped - CGFloat(index)))
                        Button { selection = item.page } label: {
                            Text(item.title)
                                .font(.subheadline.weight(near > 0.5 ? .semibold : .regular))
                                .foregroundStyle(near > 0.5 ? Color.primary : Color.secondary)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(item.page == selection ? .isSelected : [])
                        .accessibilityIdentifier("\(identifier).\(index)")
                    }
                }
            }
        }
        .frame(width: CGFloat(pages.count) * 84, height: 32)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(identifier)
    }
}

//
//  Copyright (c) 2021 Open Whisper Systems. All rights reserved.
//

import Foundation

@objc class OWSImagePickerController: UIImagePickerController {

    // MARK: Orientation

    override public var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return UIDevice.current.defaultSupportedOrientations
    }
}

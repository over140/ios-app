import UIKit

class VerificationCodeViewController: ContinueButtonViewController {
    
    @IBOutlet weak var contentStackView: UIStackView!
    @IBOutlet weak var titleLabel: UILabel!
    @IBOutlet weak var verificationCodeField: VerificationCodeField!
    @IBOutlet weak var resendButton: CountDownButton!
    
    let resendInterval = 60
    
    var isBusy = false {
        didSet {
            continueButton.isBusy = isBusy
            verificationCodeField.receivesInput = !isBusy
        }
    }
    
    convenience init() {
        self.init(nib: R.nib.verificationCodeView)
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        if ScreenSize.current == .inch3_5 {
            contentStackView.spacing = 12
        } else if ScreenSize.current == .inch4 {
            contentStackView.spacing = 24
        }
        resendButton.normalTitle = Localized.BUTTON_TITLE_RESEND_CODE
        resendButton.pendingTitleTemplate = Localized.BUTTON_TITLE_RESEND_CODE_PENDING
        resendButton.beginCountDown(resendInterval)
        verificationCodeField.becomeFirstResponder()
    }
    
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        resendButton.restartTimerIfNeeded()
    }
    
    override func viewDidDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        resendButton.releaseTimer()
    }
    
    @IBAction func verificationCodeFieldEditingChanged(_ sender: Any) {
        
    }
    
    @IBAction func resendAction(_ sender: Any) {
        resendButton.isBusy = true
        requestVerificationCode(reCaptchaToken: nil)
    }
    
    func requestVerificationCode(reCaptchaToken token: String?) {
        
    }
    
}

import Foundation

struct LoginContext {
    let callingCode: String
    let mobileNumber: String
    let fullNumber: String
    var verificationId = ""
    
    init(callingCode: String, mobileNumber: String, fullNumber: String) {
        self.callingCode = callingCode
        self.mobileNumber = mobileNumber
        self.fullNumber = fullNumber
    }
    
}

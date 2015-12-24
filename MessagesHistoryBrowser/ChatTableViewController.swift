//
//  ChatTableViewController.swift
//  MessagesHistoryBrowser
//
//  Created by Guillaume Laurent on 25/10/15.
//  Copyright © 2015 Guillaume Laurent. All rights reserved.
//

import Cocoa

class ChatTableViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {

    @IBOutlet weak var tableView: NSTableView!
    @IBOutlet weak var searchField: NSSearchField!
    @IBOutlet weak var afterDatePicker: NSDatePicker!
    @IBOutlet weak var beforeDatePicker: NSDatePicker!

    @IBOutlet weak var dbPopulateProgressIndicator: NSProgressIndicator!
    @IBOutlet weak var progressReportView: NSView!

    dynamic var progress:NSProgress = NSProgress(totalUnitCount: 700)

    var chatsDatabase:ChatsDatabase!

    var messagesListViewController:MessagesListViewController?

    var allKnownContacts = [ChatContact]()
    var allUnknownContacts = [ChatContact]()

    lazy var moc = (NSApp.delegate as! AppDelegate).managedObjectContext

    var messageFormatter = MessageFormatter()

    var showChatsFromUnknown = false
    
    var searchTerm:String?
    var searchedContacts:[ChatContact]?
    var searchedMessages:[ChatMessage]?

    dynamic var beforeDateEnabled = false
    dynamic var afterDateEnabled = false
    
    dynamic var beforeDate = NSDate()
    dynamic var afterDate = NSDate()

    var hasChatSelected:Bool {
        get { return tableView != nil && tableView.selectedRow >= 0 }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        // Do view setup here.

        let appDelegate = NSApp.delegate as! AppDelegate
        appDelegate.chatTableViewController = self

        chatsDatabase = ChatsDatabase.sharedInstance

        if let parentSplitViewController = parentViewController as? NSSplitViewController {
            let secondSplitViewItem = parentSplitViewController.splitViewItems[1]

            messagesListViewController = secondSplitViewItem.viewController as? MessagesListViewController
        }

        NSNotificationCenter.defaultCenter().addObserver(self, selector: "showUnknownContactsChanged:", name: AppDelegate.ShowChatsFromUnknownNotification, object: nil)

//        progress.addObserver(self, forKeyPath: "localizedDescription", options: NSKeyValueObservingOptions.New, context: nil)

//        progress.addObserver(self, forKeyPath: "fractionCompleted", options: NSKeyValueObservingOptions.New, context: nil)

        chatsDatabase.populate(progress, completion: { () -> Void in
            self.progressReportView.hidden = true
            self.allKnownContacts = ChatContact.allKnownContactsInContext(self.moc)
            self.allUnknownContacts = ChatContact.allUnknownContactsInContext(self.moc)
            self.tableView.reloadData()

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) { () -> Void in
                do { try self.moc.save() } catch { NSLog("DB save failed") } // TODO : what if this occurs while app is quitting ? AppDelegate saves the DB too
            }

        })

    }

    func showUnknownContactsChanged(notification:NSNotification)
    {
        let appDelegate = NSApp.delegate as! AppDelegate
        showChatsFromUnknown = appDelegate.showChatsFromUnknown
        tableView.reloadData()
    }

    func contactForRow(row:Int) -> ChatContact?
    {
        
        guard (searchTerm != nil && row < searchedContacts!.count) || (showChatsFromUnknown && row < allKnownContacts.count + allUnknownContacts.count) || row < allKnownContacts.count else { return nil }
        
        var contact:ChatContact

        if searchTerm != nil {
            
            contact = searchedContacts![row]
            
        } else {
            if showChatsFromUnknown && row >= allKnownContacts.count {
                contact = allUnknownContacts[row - allKnownContacts.count]
            } else {
                contact = allKnownContacts[row]
            }
        }
        return contact
    }

    // MARK: NSTableView datasource & delegate

    func numberOfRowsInTableView(tableView: NSTableView) -> Int
    {
        if searchTerm != nil {
            return searchedContacts?.count ?? 0
        }
        
        if showChatsFromUnknown {
            return allKnownContacts.count + allUnknownContacts.count
        }

        return allKnownContacts.count
    }


    func tableView(tableView: NSTableView, viewForTableColumn tableColumn: NSTableColumn?, row: Int) -> NSView?
    {
        guard let tableColumn = tableColumn else { return nil }

        let cellView = tableView.makeViewWithIdentifier(tableColumn.identifier, owner: self) as! NSTableCellView

        if let contact = contactForRow(row) {
            cellView.textField?.stringValue = contact.name
        }
        
        return cellView
    }

    func tableViewSelectionDidChange(notification: NSNotification)
    {
        let index = tableView.selectedRowIndexes.firstIndex // no multiple selection

        if let selectedContact = contactForRow(index) {

            if let searchTerm = searchTerm, searchedMessages = searchedMessages {

                let allContactMessages = searchedMessages.filter({ (message) -> Bool in
                    return message.contact == selectedContact
                })

                messagesListViewController?.showMessages(allContactMessages, withHighlightTerm:searchTerm)

            } else { // no search term, display full chat history of contact, with attachments

                chatsDatabase.collectMessagesForContact(selectedContact)

                // sort attachments by date
                //
                let allContactAttachmentsT = selectedContact.attachments.allObjects.sort(ChatsDatabase.sharedInstance.messageDateSort)

                let allContactChatItems = selectedContact.messages.setByAddingObjectsFromSet(selectedContact.attachments as Set<NSObject>) // COMMENT THIS LINE TO FIX COMPILE ERROR IN AppDelegate

                let allContactChatItemsSorted = allContactChatItems.sort(chatsDatabase.messageDateSort) as! [ChatItem]

                messagesListViewController?.hideAttachmentDisplayWindow()
                messagesListViewController?.attachmentsToDisplay = allContactAttachmentsT as? [ChatAttachment]
                messagesListViewController?.attachmentsCollectionView.reloadData()
                messagesListViewController?.showMessages(allContactChatItemsSorted)
            }

        } else { // no contact selected, clean up

            if let searchTerm = searchTerm, searchedMessages = searchedMessages {
                messagesListViewController?.showMessages(searchedMessages, withHighlightTerm: searchTerm)
            } else {
                messagesListViewController?.showMessages([ChatMessage]())
            }
        }
    }

    // MARK: actions

    func chatIDsForSelectedRows(selectedRowIndexes : NSIndexSet) -> [Chat]
    {
        let index = selectedRowIndexes.firstIndex // no multiple selection

        guard let selectedContact = contactForRow(index) else { return [Chat]() }

        return selectedContact.chats.allObjects as! [Chat]

    }

    @IBAction func search(sender: NSSearchField) {

        NSLog("search for '\(sender.stringValue)'")

        if sender.stringValue == "" {
            
            searchTerm = nil
            searchedContacts = nil

            messagesListViewController?.clearMessages()
            tableView.reloadData()
            
        } else if sender.stringValue.characters.count >= 3 {

            searchTerm = sender.stringValue

            chatsDatabase.searchChatsForString(searchTerm!,
                afterDate: afterDateEnabled ? afterDate : nil,
                beforeDate: beforeDateEnabled ? beforeDate : nil,
                completion: { (matchingMessages) -> (Void) in
                    let matchingMessagesSorted = matchingMessages.sort(ChatsDatabase.sharedInstance.messageDateSort)
                    
                    self.messagesListViewController?.showMessages(matchingMessagesSorted, withHighlightTerm:self.searchTerm)
                    
                    self.searchedContacts = self.contactsFromMessages(matchingMessages)
                    self.searchedMessages = matchingMessagesSorted
                    self.tableView.reloadData()
            })
            
//            let matchingMessages = ChatsDatabase.sharedInstance.searchChatsForString(searchTerm,
//                afterDate: afterDateEnabled ? afterDate : nil,
//                beforeDate: beforeDateEnabled ? beforeDate : nil)
//
//            let matchingMessagesSorted = matchingMessages.sort(ChatsDatabase.sharedInstance.messageDateSort)
//
//            messagesListViewController?.showMessages(matchingMessagesSorted, withHighlightTerm:searchTerm)
//
//            searchedContacts = contactsFromMessages(matchingMessages)
//            searchMode = true
            
        }
        
//        tableView.reloadData()
    }

    // restart a search once one of the date pickers has been changed
    //
    @IBAction func redoSearch(sender: NSObject) {
        if sender == afterDatePicker {
            afterDateEnabled = true
        }
        if sender == beforeDatePicker {
            beforeDateEnabled = true
        }

        search(searchField)
    }
    

    func contactsFromMessages(messages: [ChatMessage]) -> [ChatContact]
    {
        let allContacts = messages.map { (message) -> ChatContact in
            return message.contact
        }
        
        var contactList = [String:ChatContact]()
        
        let uniqueContacts = allContacts.filter { (contact) -> Bool in
            if contactList[contact.name] != nil {
                return false
            }
            contactList[contact.name] = contact
            return true
        }
        
        return uniqueContacts
    }


//    override func observeValueForKeyPath(keyPath: String?, ofObject object: AnyObject?, change: [String : AnyObject]?, context: UnsafeMutablePointer<Void>) {
//        print("\(__FUNCTION__) : \(change)")

//        if keyPath == "fractionCompleted" {
//            let newValue = change!["new"] as! NSNumber
//            dbPopulateProgressIndicator.doubleValue = newValue.doubleValue
//        }
//    }

    // MARK: file save

    enum SaveError : ErrorType {
        case dataConversionFailed
    }

    func saveContactChats(contact:ChatContact, atURL url:NSURL)
    {
        do {

            chatsDatabase.collectMessagesForContact(contact)

            let messages = contact.messages.sort(chatsDatabase.messageDateSort) as! [ChatMessage]

            let reducer = { (currentValue:String, message:ChatMessage) -> String in
                return currentValue + "\n" + self.messageFormatter.formatMessageAsString(message)
            }

            let allMessagesAsString = messages.reduce("", combine:reducer)

            let tmpNSString = NSString(string: allMessagesAsString)

            if let data = tmpNSString.dataUsingEncoding(NSUTF8StringEncoding) {

                NSFileManager.defaultManager().createFileAtPath(url.path!, contents: data, attributes: nil)

            } else {
                throw SaveError.dataConversionFailed
            }

        } catch {
            NSLog("save failed")
        }
    }

    @IBAction func saveChat(sender:AnyObject)
    {
        guard let window = view.window else { return }

        guard let selectedContact = contactForRow(tableView.selectedRow) else { return }

        let savePanel = NSSavePanel()

        savePanel.nameFieldStringValue = selectedContact.name

        savePanel.beginSheetModalForWindow(window) { (modalResponse) -> Void in
            NSLog("do save at URL \(savePanel.URL)")

            guard let saveURL = savePanel.URL else { return }

            self.saveContactChats(selectedContact, atURL: saveURL)
        }
    }

    func refreshChatHistory() {

        let appDelegate = NSApp.delegate as! AppDelegate

        appDelegate.clearAllCoreData()

        tableView.reloadData()
        
        progressReportView.hidden = false

        ChatsDatabase.sharedInstance.populate(progress) { () -> Void in
            self.progressReportView.hidden = true
            self.allKnownContacts = ChatContact.allKnownContactsInContext(self.moc)
            self.allUnknownContacts = ChatContact.allUnknownContactsInContext(self.moc)
            self.tableView.reloadData()

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0)) { () -> Void in
                do { try self.moc.save() } catch { NSLog("DB save failed") } // TODO : what if this occurs while app is quitting ? AppDelegate saves the DB too
            }
        }

    }

}

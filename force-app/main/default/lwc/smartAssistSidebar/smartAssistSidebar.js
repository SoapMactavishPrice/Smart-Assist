import { LightningElement, wire } from 'lwc';
import { MessageContext, publish } from 'lightning/messageService';
import SMART_ASSIST_NAVIGATION from '@salesforce/messageChannel/SmartAssistNavigation__c';

const PRODUCTS_ACTION = 'NAVIGATE_TO_PRODUCTS';
const CASES_ACTION = 'NAVIGATE_TO_CASES';

export default class SmartAssistSidebar extends LightningElement {
    @wire(MessageContext)
    messageContext;

    activeAction = PRODUCTS_ACTION;

    get productsClass() {
        return this.activeAction === PRODUCTS_ACTION ? 'nav-item active' : 'nav-item';
    }

    get casesClass() {
        return this.activeAction === CASES_ACTION ? 'nav-item active' : 'nav-item';
    }

    handleNavigate(event) {
        const action = event.currentTarget.dataset.action;
        this.activeAction = action;
        publish(this.messageContext, SMART_ASSIST_NAVIGATION, { action });
    }
}

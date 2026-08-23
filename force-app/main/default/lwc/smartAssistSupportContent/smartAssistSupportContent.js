import { LightningElement, wire } from 'lwc';
import { MessageContext, subscribe, unsubscribe, APPLICATION_SCOPE } from 'lightning/messageService';
import SMART_ASSIST_NAVIGATION from '@salesforce/messageChannel/SmartAssistNavigation__c';
import getMyAssets from '@salesforce/apex/SmartAssistSupportController.getMyAssets';
import getMyCases from '@salesforce/apex/SmartAssistSupportController.getMyCases';
import analyzeSupportRequest from '@salesforce/apex/SmartAssistSupportController.analyzeSupportRequest';
import createSupportCase from '@salesforce/apex/SmartAssistSupportController.createSupportCase';
import resolveConversation from '@salesforce/apex/SmartAssistSupportController.resolveConversation';

const VIEW_PRODUCTS = 'PRODUCT_LIST';
const VIEW_SUPPORT = 'PRODUCT_SUPPORT';
const VIEW_CASES = 'MY_CASES';
const STEP_QUESTION = 'QUESTION';
const STEP_SATISFACTION = 'SATISFACTION';
const STEP_CREATE_CASE = 'CREATE_CASE';
const STEP_AUTO_CASE = 'AUTO_CASE';
const STEP_CASE_CREATED = 'CASE_CREATED';
const STEP_RESOLVED = 'RESOLVED';

export default class SmartAssistSupportContent extends LightningElement {
    @wire(MessageContext)
    messageContext;

    subscription;
    currentView = VIEW_PRODUCTS;
    supportStep = STEP_QUESTION;
    products = [];
    cases = [];
    selectedAssetId;
    selectedProduct;
    question = '';
    analysis;
    caseNumber;
    errorMessage;
    isLoadingProducts = false;
    isLoadingCases = false;
    isProcessing = false;

    connectedCallback() {
        this.subscribeToNavigation();
        this.loadProducts();
    }

    disconnectedCallback() {
        unsubscribe(this.subscription);
        this.subscription = undefined;
    }

    get isProductList() {
        return this.currentView === VIEW_PRODUCTS;
    }

    get isSupport() {
        return this.currentView === VIEW_SUPPORT;
    }

    get isCases() {
        return this.currentView === VIEW_CASES;
    }

    get hasError() {
        return Boolean(this.errorMessage);
    }

    get showProducts() {
        return !this.isLoadingProducts && this.products.length > 0;
    }

    get showEmptyProducts() {
        return !this.isLoadingProducts && this.products.length === 0;
    }

    get showCases() {
        return !this.isLoadingCases && this.cases.length > 0;
    }

    get showEmptyCases() {
        return !this.isLoadingCases && this.cases.length === 0;
    }

    get showQuestionForm() {
        return this.supportStep === STEP_QUESTION;
    }

    get hasAiResult() {
        return Boolean(this.analysis);
    }

    get showSatisfactionQuestion() {
        return this.supportStep === STEP_SATISFACTION;
    }

    get showCreateCaseQuestion() {
        return this.supportStep === STEP_CREATE_CASE;
    }

    get showAutoCaseMessage() {
        return this.supportStep === STEP_AUTO_CASE && !this.caseNumber;
    }

    get caseCreated() {
        return this.supportStep === STEP_CASE_CREATED && Boolean(this.caseNumber);
    }

    get conversationResolved() {
        return this.supportStep === STEP_RESOLVED;
    }

    get confidenceLabel() {
        return this.analysis ? `${this.analysis.confidenceScore}% confidence` : '';
    }

    subscribeToNavigation() {
        if (this.subscription) {
            return;
        }
        this.subscription = subscribe(
            this.messageContext,
            SMART_ASSIST_NAVIGATION,
            (message) => this.handleNavigationMessage(message),
            { scope: APPLICATION_SCOPE }
        );
    }

    handleNavigationMessage(message) {
        if (message?.action === 'NAVIGATE_TO_PRODUCTS') {
            this.currentView = VIEW_PRODUCTS;
            this.clearSupportState();
            this.loadProducts();
        } else if (message?.action === 'NAVIGATE_TO_CASES') {
            this.currentView = VIEW_CASES;
            this.clearSupportState();
            this.loadCases();
        }
    }

    async loadProducts() {
        this.errorMessage = undefined;
        this.isLoadingProducts = true;
        try {
            this.products = await getMyAssets();
        } catch (error) {
            this.products = [];
            this.errorMessage = this.normalizeError(error, 'Unable to load your products. Please try again.');
        } finally {
            this.isLoadingProducts = false;
        }
    }

    async loadCases() {
        this.errorMessage = undefined;
        this.isLoadingCases = true;
        try {
            this.cases = await getMyCases();
        } catch (error) {
            this.cases = [];
            this.errorMessage = this.normalizeError(error, 'Unable to load your cases. Please try again.');
        } finally {
            this.isLoadingCases = false;
        }
    }

    handleGetSupport(event) {
        this.selectedAssetId = event.currentTarget.dataset.id;
        this.selectedProduct = this.products.find((product) => product.assetId === this.selectedAssetId);
        this.currentView = VIEW_SUPPORT;
        this.supportStep = STEP_QUESTION;
        this.errorMessage = undefined;
        this.analysis = undefined;
        this.caseNumber = undefined;
        this.question = '';
    }

    handleBackToProducts() {
        this.currentView = VIEW_PRODUCTS;
        this.clearSupportState();
    }

    handleQuestionChange(event) {
        this.question = event.target.value;
    }

    async handleAskSmartAssist() {
        if (!this.question || !this.question.trim()) {
            this.errorMessage = "Please describe the issue you're experiencing.";
            return;
        }
        if (this.isProcessing) {
            return;
        }

        this.errorMessage = undefined;
        this.isProcessing = true;
        this.analysis = undefined;
        this.caseNumber = undefined;

        try {
            const result = await analyzeSupportRequest({
                assetId: this.selectedAssetId,
                question: this.question.trim()
            });
            this.analysis = result;
            if (result.caseCreated) {
                this.caseNumber = result.caseNumber;
                this.supportStep = STEP_CASE_CREATED;
            } else if (result.requiresCase) {
                this.supportStep = STEP_AUTO_CASE;
                this.isProcessing = false;
                await this.createCaseFromConversation();
            } else {
                this.supportStep = STEP_SATISFACTION;
            }
        } catch (error) {
            this.errorMessage = this.normalizeError(error, 'SmartAssist is temporarily unavailable. Please try again.');
            this.supportStep = STEP_QUESTION;
        } finally {
            this.isProcessing = false;
        }
    }

    async handleResolved() {
        this.errorMessage = undefined;
        try {
            await resolveConversation({ aiConversationId: this.analysis.aiConversationId });
            this.supportStep = STEP_RESOLVED;
        } catch (error) {
            this.errorMessage = this.normalizeError(error, "We couldn't update your request. Please try again.");
        }
    }

    handleNeedHelp() {
        this.supportStep = STEP_CREATE_CASE;
        this.errorMessage = undefined;
    }

    async handleCreateCase() {
        await this.createCaseFromConversation();
    }

    async createCaseFromConversation() {
        if (this.isProcessing) {
            return;
        }
        this.isProcessing = true;
        this.errorMessage = undefined;
        try {
            const result = await createSupportCase({ aiConversationId: this.analysis.aiConversationId });
            this.caseNumber = result.caseNumber;
            this.supportStep = STEP_CASE_CREATED;
        } catch (error) {
            this.errorMessage = this.normalizeError(error, "We couldn't create your support case. Please try again.");
        } finally {
            this.isProcessing = false;
        }
    }

    clearSupportState() {
        this.supportStep = STEP_QUESTION;
        this.selectedAssetId = undefined;
        this.selectedProduct = undefined;
        this.question = '';
        this.analysis = undefined;
        this.caseNumber = undefined;
        this.errorMessage = undefined;
        this.isProcessing = false;
    }

    normalizeError(error, fallback) {
        return error?.body?.message || error?.message || fallback;
    }
}

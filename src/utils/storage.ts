import AsyncStorage from '@react-native-async-storage/async-storage';
import { Message } from '../models/Message';

const MESSAGES_KEY = 'stored_messages';
const USER_PASSWORD_KEY = 'user_password';

export const storeMessage = async (message: Message) => {
    try {
        const messages = await getStoredMessages();
        messages.push(message);
        await AsyncStorage.setItem(MESSAGES_KEY, JSON.stringify(messages));
    } catch (error) {
        console.error('Error storing message:', error);
    }
};

export const getStoredMessages = async (): Promise<Message[]> => {
    try {
        const messages = await AsyncStorage.getItem(MESSAGES_KEY);
        return messages ? JSON.parse(messages) : [];
    } catch (error) {
        console.error('Error getting messages:', error);
        return [];
    }
};

export const storeUserPassword = async (password: string) => {
    await AsyncStorage.setItem(USER_PASSWORD_KEY, password);
};

export const getUserPassword = async (): Promise<string | null> => {
    return await AsyncStorage.getItem(USER_PASSWORD_KEY);
};

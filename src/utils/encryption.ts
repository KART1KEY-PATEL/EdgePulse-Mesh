import CryptoJS from 'crypto-js';

export const encryptFile = (fileData: ArrayBuffer, password: string): string => {
    const wordArray = CryptoJS.lib.WordArray.create(fileData);
    return CryptoJS.AES.encrypt(wordArray, password).toString();
};

export const decryptFile = (encryptedData: string, password: string): ArrayBuffer => {
    const decrypted = CryptoJS.AES.decrypt(encryptedData, password);
    return decrypted.toArrayBuffer();
};

export const verifyPassword = (encryptedData: string, password: string): boolean => {
    try {
        CryptoJS.AES.decrypt(encryptedData, password);
        return true;
    } catch {
        return false;
    }
};

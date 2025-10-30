import React, { useState } from 'react';
import { View, TextInput, Button, StyleSheet } from 'react-native';
import { storeUserPassword } from '../utils/storage';

export const PasswordSetupScreen = ({ onComplete }: { onComplete: () => void }) => {
    const [password, setPassword] = useState('');

    const handleSubmit = async () => {
        if (password.length >= 6) {
            await storeUserPassword(password);
            onComplete();
        }
    };

    return (
        <View style={styles.container}>
            <TextInput
                secureTextEntry
                placeholder="Set your file access password"
                value={password}
                onChangeText={setPassword}
                style={styles.input}
            />
            <Button title="Set Password" onPress={handleSubmit} />
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        flex: 1,
        padding: 20,
        justifyContent: 'center',
    },
    input: {
        borderWidth: 1,
        padding: 10,
        marginBottom: 20,
    },
});

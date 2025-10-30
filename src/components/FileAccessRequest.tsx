import React from 'react';
import { View, Text, Button, StyleSheet } from 'react-native';
import { FileAccessRequest } from '../models/Message';

interface Props {
    request: FileAccessRequest;
    onApprove: (password: string) => void;
    onDeny: () => void;
}

export const FileAccessRequestComponent = ({ request, onApprove, onDeny }: Props) => {
    const [password, setPassword] = useState('');

    return (
        <View style={styles.container}>
            <Text>File access request from {request.requesterName}</Text>
            <TextInput
                secureTextEntry
                placeholder="Enter file password"
                value={password}
                onChangeText={setPassword}
                style={styles.input}
            />
            <View style={styles.buttonContainer}>
                <Button title="Approve" onPress={() => onApprove(password)} />
                <Button title="Deny" onPress={onDeny} />
            </View>
        </View>
    );
};

const styles = StyleSheet.create({
    container: {
        padding: 10,
        borderWidth: 1,
        margin: 5,
    },
    input: {
        borderWidth: 1,
        padding: 5,
        marginVertical: 10,
    },
    buttonContainer: {
        flexDirection: 'row',
        justifyContent: 'space-around',
    },
});
